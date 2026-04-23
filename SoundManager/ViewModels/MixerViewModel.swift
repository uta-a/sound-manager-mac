import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class MixerViewModel {
    private let client: AudioObjectClientProtocol
    private var suppressVolumeWrite = false

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var volumeIsReadable: Bool = true

    var selectedOutputID: AudioDeviceID? {
        didSet {
            guard let id = selectedOutputID, id != oldValue else { return }
            if client.setDefaultOutputDevice(id: id) {
                refreshVolume()
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
    }

    func refresh() {
        outputDevices = client.enumerateOutputDevices()

        let currentDefault = client.getDefaultOutputDevice()
        suppressVolumeWrite = true
        selectedOutputID = currentDefault
        suppressVolumeWrite = false

        refreshVolume()
    }

    private func refreshVolume() {
        suppressVolumeWrite = true
        defer { suppressVolumeWrite = false }

        guard let id = selectedOutputID,
              let value = client.getOutputVolumeScalar(id: id) else {
            volumeIsReadable = false
            volume = 0
            return
        }
        volumeIsReadable = true
        volume = Double(value)
    }
}
