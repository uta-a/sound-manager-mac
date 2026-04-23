import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class MixerViewModel {
    private let client: AudioObjectClientProtocol
    private let runningApps: RunningAppsMonitor

    private var suppressVolumeWrite = false
    private var suppressDeviceWrite = false
    private var defaultOutputListener: PropertyListenerHandle?
    private var volumeListener: PropertyListenerHandle?
    private var activeClientsListener: PropertyListenerHandle?

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

    /// 指定 bundleID の音量を更新する。M4 で driver に送信する予定。
    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = max(0, min(1, value))
        perAppVolumes[bundleID] = clamped
        // TODO(M4): driver の kSMCustomPropertyAppVolumes 相当に反映する
    }

    var selectedOutputID: AudioDeviceID? {
        didSet {
            guard !suppressDeviceWrite else { return }
            guard let id = selectedOutputID, id != oldValue else { return }
            if client.setDefaultOutputDevice(id: id) {
                refreshVolume()
                installVolumeListener()
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
        activeApps = ProcessGrouping.buildActiveApps(from: activeClients) { [runningApps] bundleID in
            guard let info = runningApps.appsByBundleID[bundleID] else { return nil }
            return (info.displayName, info.icon)
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
