import CoreAudio
import Foundation

enum AudioScope {
    case global
    case input
    case output

    var rawValue: AudioObjectPropertyScope {
        switch self {
        case .global: return kAudioObjectPropertyScopeGlobal
        case .input: return kAudioDevicePropertyScopeInput
        case .output: return kAudioDevicePropertyScopeOutput
        }
    }
}

struct AudioObjectClient {
    func enumerateDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }
        return devices
    }

    func getDeviceName(id: AudioDeviceID) -> String? {
        readCFString(id: id, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    func getDeviceUID(id: AudioDeviceID) -> String? {
        readCFString(id: id, selector: kAudioDevicePropertyDeviceUID)
    }

    func getManufacturer(id: AudioDeviceID) -> String? {
        readCFString(id: id, selector: kAudioDevicePropertyDeviceManufacturerCFString)
    }

    func getChannelCount(id: AudioDeviceID, scope: AudioScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope.rawValue,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }

        let ablPointer = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func getNominalSampleRate(id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    func getTransportType(id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
        return transportTypeName(value)
    }

    func getDefaultOutputDevice() -> AudioDeviceID? {
        readSystemObjectUInt32(selector: kAudioHardwarePropertyDefaultOutputDevice)
            .map { AudioDeviceID($0) }
    }

    func getDefaultInputDevice() -> AudioDeviceID? {
        readSystemObjectUInt32(selector: kAudioHardwarePropertyDefaultInputDevice)
            .map { AudioDeviceID($0) }
    }

    /// master volume (scalar 0.0 - 1.0) for output, if supported
    func getOutputVolumeScalar(id: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private func readCFString(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfString)
        guard status == noErr, let result = cfString?.takeRetainedValue() else { return nil }
        return result as String
    }

    private func readSystemObjectUInt32(selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &value
        ) == noErr else { return nil }
        return value
    }

    private func transportTypeName(_ value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
        case kAudioDeviceTransportTypeUnknown: return "Unknown"
        default:
            return String(format: "0x%08x", value)
        }
    }
}
