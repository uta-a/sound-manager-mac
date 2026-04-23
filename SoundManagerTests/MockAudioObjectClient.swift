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

    // Listener メソッドは AudioObjectClientProtocol の extension で nil を
    // 返すデフォルト実装が提供されているため、override しない。
}

extension AudioDevice {
    static func makeStub(
        id: AudioDeviceID,
        name: String,
        outputChannels: Int = 2,
        inputChannels: Int = 0,
        transport: String = "Virtual"
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            name: name,
            uid: "mock-\(id)",
            manufacturer: "Mock Manufacturer",
            transport: transport,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            sampleRate: 48000
        )
    }
}
