import CoreAudio
import Foundation
@testable import SoundManager

final class MockAudioObjectClient: AudioObjectClientProtocol {
    var outputDevicesToReturn: [AudioDevice] = []
    var defaultOutputDeviceToReturn: AudioDeviceID?
    var volumesByID: [AudioDeviceID: Float] = [:]

    private(set) var setDefaultOutputCalls: [AudioDeviceID] = []
    private(set) var setVolumeCalls: [(id: AudioDeviceID, volume: Float)] = []
    private(set) var enumerateCount = 0

    // Listener 発火を模擬するためのキャプチャ
    var capturedDefaultOutputListener: (() -> Void)?
    var capturedVolumeListener: (() -> Void)?
    var capturedVolumeListenerDeviceID: AudioDeviceID?
    var capturedActiveClientsListener: (() -> Void)?
    var capturedActiveClientsListenerDeviceID: AudioDeviceID?

    // kSMCustomPropertyActiveClients をエミュレートする: deviceID 単位で保持する
    var activeClientsByDeviceID: [AudioDeviceID: [ActiveClient]] = [:]

    func enumerateOutputDevices() -> [AudioDevice] {
        enumerateCount += 1
        return outputDevicesToReturn
    }

    func getDefaultOutputDevice() -> AudioDeviceID? {
        defaultOutputDeviceToReturn
    }

    func setDefaultOutputDevice(id: AudioDeviceID) -> Bool {
        setDefaultOutputCalls.append(id)
        defaultOutputDeviceToReturn = id
        return true
    }

    func getOutputVolumeScalar(id: AudioDeviceID) -> Float? {
        volumesByID[id]
    }

    func setOutputVolumeScalar(id: AudioDeviceID, volume: Float) -> Bool {
        setVolumeCalls.append((id, volume))
        volumesByID[id] = volume
        return true
    }

    func addDefaultOutputDeviceListener(_ handler: @escaping () -> Void) -> PropertyListenerHandle? {
        capturedDefaultOutputListener = handler
        return nil
    }

    func addOutputVolumeListener(id: AudioDeviceID, _ handler: @escaping () -> Void) -> PropertyListenerHandle? {
        capturedVolumeListener = handler
        capturedVolumeListenerDeviceID = id
        return nil
    }

    func getActiveClients(deviceID: AudioDeviceID) -> [ActiveClient]? {
        activeClientsByDeviceID[deviceID]
    }

    func addActiveClientsListener(deviceID: AudioDeviceID, _ handler: @escaping () -> Void) -> PropertyListenerHandle? {
        capturedActiveClientsListener = handler
        capturedActiveClientsListenerDeviceID = deviceID
        return nil
    }
}

extension AudioDevice {
    static func makeStub(
        id: AudioDeviceID,
        name: String,
        outputChannels: Int = 2,
        inputChannels: Int = 0,
        transport: String = "Virtual",
        manufacturer: String = "Mock Manufacturer"
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            name: name,
            uid: "mock-\(id)",
            manufacturer: manufacturer,
            transport: transport,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            sampleRate: 48000
        )
    }
}
