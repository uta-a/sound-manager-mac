import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class MixerViewModel {
    private let client: AudioObjectClientProtocol
    private let runningApps: RunningAppsMonitor
    private let loopback = LoopbackEngine()
    private let ownBundleID: String = Bundle.main.bundleIdentifier ?? ""

    private var suppressVolumeWrite = false
    private var suppressDeviceWrite = false
    private var suppressAppVolumesWrite = false
    private var defaultOutputListener: PropertyListenerHandle?
    private var volumeListener: PropertyListenerHandle?
    private var activeClientsListener: PropertyListenerHandle?
    private var appVolumesListener: PropertyListenerHandle?

    /// SoundManager が既定出力になる前の実出力デバイス ID。
    /// SoundManager 選択時に、これを LoopbackEngine の出力先として使う。
    private var lastPhysicalOutputID: AudioDeviceID?

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var volumeIsReadable: Bool = true
    private(set) var activeClients: [ActiveClient] = []
    private(set) var activeApps: [ActiveApp] = []
    private(set) var soundManagerDeviceID: AudioDeviceID?

    /// per-app 音量状態。bundleID → [0.0, 1.0] の値を保持する。
    /// M3 段階では UI のみ保存し、実際のオーディオ gain 反映は M4 で driver 側と連携する。
    private var perAppVolumes: [String: Double] = [:]

    /// 指定 bundleID の現在音量 (未設定は 1.0 = unity)。
    func volume(for bundleID: String) -> Double {
        perAppVolumes[bundleID] ?? 1.0
    }

    /// 指定 bundleID の音量を更新する。
    /// Driver の kSMCustomPropertyAppVolumes に全マップを書き込み、
    /// Handler::OnProcessClientOutput で対応する client の音量が実際に変わる。
    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = max(0, min(1, value))
        perAppVolumes[bundleID] = clamped
        if suppressAppVolumesWrite { return }
        guard let id = soundManagerDeviceID else { return }
        let driverMap = perAppVolumes.mapValues { Float($0) }
        _ = client.setAppVolumes(deviceID: id, volumes: driverMap)
    }

    var selectedOutputID: AudioDeviceID? {
        didSet {
            guard !suppressDeviceWrite else { return }
            guard let id = selectedOutputID, id != oldValue else { return }
            if client.setDefaultOutputDevice(id: id) {
                refreshVolume()
                installVolumeListener()
                updateLoopback()
            }
        }
    }

    var volume: Double = 0 {
        didSet {
            guard !suppressVolumeWrite else { return }
            guard let id = selectedOutputID else { return }
            _ = client.setOutputVolumeScalar(id: id, volume: Float(volume))
        }
    }

    init(client: AudioObjectClientProtocol = AudioObjectClient()) {
        self.client = client
        self.runningApps = RunningAppsMonitor()
        self.runningApps.onChange = { [weak self] in
            self?.rebuildActiveApps()
        }
        refresh()
        startObservingSystem()
    }

    func refresh() {
        outputDevices = client.enumerateOutputDevices()

        let currentDefault = client.getDefaultOutputDevice()
        withSuppressedWrites {
            selectedOutputID = currentDefault
        }
        refreshVolume()
        rebindSoundManagerDevice()
        updateLoopback()
    }

    private func startObservingSystem() {
        defaultOutputListener = client.addDefaultOutputDeviceListener { [weak self] in
            self?.onDefaultOutputDeviceChanged()
        }
        installVolumeListener()
        installActiveClientsListener()
    }

    private func onDefaultOutputDeviceChanged() {
        let newDefault = client.getDefaultOutputDevice()
        guard newDefault != selectedOutputID else {
            refreshVolume()
            return
        }
        withSuppressedWrites {
            selectedOutputID = newDefault
        }
        refreshVolume()
        installVolumeListener()
        updateLoopback()
    }

    private func installVolumeListener() {
        volumeListener = nil
        guard let id = selectedOutputID else { return }
        volumeListener = client.addOutputVolumeListener(id: id) { [weak self] in
            self?.refreshVolume()
        }
    }

    private func refreshVolume() {
        guard let id = selectedOutputID,
              let value = client.getOutputVolumeScalar(id: id) else {
            withSuppressedWrites {
                volumeIsReadable = false
                volume = 0
            }
            return
        }
        let newVolume = Double(value)
        guard abs(newVolume - volume) > 0.0001 || !volumeIsReadable else { return }
        withSuppressedWrites {
            volumeIsReadable = true
            volume = newVolume
        }
    }

    // MARK: - SoundManager custom property (active clients)

    private func rebindSoundManagerDevice() {
        soundManagerDeviceID = outputDevices.first { $0.manufacturer == "SoundManager" }?.id
        refreshActiveClients()
        installActiveClientsListener()
        refreshAppVolumes()
        installAppVolumesListener()
    }

    private func refreshAppVolumes() {
        guard let id = soundManagerDeviceID,
              let driverMap = client.getAppVolumes(deviceID: id) else { return }
        suppressAppVolumesWrite = true
        defer { suppressAppVolumesWrite = false }
        perAppVolumes = driverMap.mapValues { Double($0) }
    }

    private func installAppVolumesListener() {
        appVolumesListener = nil
        guard let id = soundManagerDeviceID else { return }
        appVolumesListener = client.addAppVolumesListener(deviceID: id) { [weak self] in
            self?.refreshAppVolumes()
        }
    }

    private func refreshActiveClients() {
        guard let id = soundManagerDeviceID else {
            activeClients = []
            rebuildActiveApps()
            return
        }
        activeClients = client.getActiveClients(deviceID: id) ?? []
        rebuildActiveApps()
    }

    private func installActiveClientsListener() {
        activeClientsListener = nil
        guard let id = soundManagerDeviceID else { return }
        activeClientsListener = client.addActiveClientsListener(deviceID: id) { [weak self] in
            self?.refreshActiveClients()
        }
    }

    // MARK: - ActiveApp: raw ActiveClient をフィルタ + グルーピング

    private func rebuildActiveApps() {
        activeApps = ProcessGrouping.buildActiveApps(
            from: activeClients,
            excludingBundleIDs: ownBundleID.isEmpty ? [] : [ownBundleID]
        ) { [runningApps] bundleID in
            guard let info = runningApps.appsByBundleID[bundleID] else { return nil }
            return (info.displayName, info.icon)
        }
    }

    // MARK: - Loopback: SoundManager → 実出力デバイス

    /// selectedOutputID が SoundManager のとき、直前の実出力デバイスに loopback する。
    /// そうでないときは実出力を覚えておき、loopback は停止する。
    private func updateLoopback() {
        guard let selected = selectedOutputID else {
            loopback.stop()
            return
        }
        if selected == soundManagerDeviceID {
            // SoundManager を既定にした場合、直前に使っていた実出力へ loopback
            guard let target = lastPhysicalOutputID, target != selected else {
                loopback.stop()
                return
            }
            loopback.start(input: selected, output: target)
        } else {
            lastPhysicalOutputID = selected
            loopback.stop()
        }
    }

    // MARK: - helpers

    private func withSuppressedWrites(_ body: () -> Void) {
        let previousVolume = suppressVolumeWrite
        let previousDevice = suppressDeviceWrite
        suppressVolumeWrite = true
        suppressDeviceWrite = true
        defer {
            suppressVolumeWrite = previousVolume
            suppressDeviceWrite = previousDevice
        }
        body()
    }
}
