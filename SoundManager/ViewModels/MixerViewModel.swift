import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class MixerViewModel {
    private let client: AudioObjectClientProtocol
    private var suppressVolumeWrite = false
    private var suppressDeviceWrite = false
    private var defaultOutputListener: PropertyListenerHandle?
    private var volumeListener: PropertyListenerHandle?

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var volumeIsReadable: Bool = true

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
    }

    private func startObservingSystem() {
        defaultOutputListener = client.addDefaultOutputDeviceListener { [weak self] in
            self?.onDefaultOutputDeviceChanged()
        }
        installVolumeListener()
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
