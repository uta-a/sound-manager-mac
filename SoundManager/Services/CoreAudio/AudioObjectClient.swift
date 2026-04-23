import CoreAudio
import Foundation

protocol AudioObjectClientProtocol {
    func enumerateOutputDevices() -> [AudioDevice]
    func getDefaultOutputDevice() -> AudioDeviceID?
    func setDefaultOutputDevice(id: AudioDeviceID) -> Bool
    func getOutputVolumeScalar(id: AudioDeviceID) -> Float?
    func setOutputVolumeScalar(id: AudioDeviceID, volume: Float) -> Bool
    func addDefaultOutputDeviceListener(_ handler: @escaping () -> Void) -> PropertyListenerHandle?
    func addOutputVolumeListener(id: AudioDeviceID, _ handler: @escaping () -> Void) -> PropertyListenerHandle?
}

extension AudioObjectClientProtocol {
    func addDefaultOutputDeviceListener(_ handler: @escaping () -> Void) -> PropertyListenerHandle? { nil }
    func addOutputVolumeListener(id: AudioDeviceID, _ handler: @escaping () -> Void) -> PropertyListenerHandle? { nil }
}

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

final class PropertyListenerHandle {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

struct AudioObjectClient: AudioObjectClientProtocol {
    func enumerateOutputDevices() -> [AudioDevice] {
        listAllDeviceIDs().compactMap { id -> AudioDevice? in
            let outputCh = channelCount(id: id, scope: .output)
            guard outputCh > 0 else { return nil }
            return buildDevice(id: id, outputCh: outputCh)
        }
    }

    func getDefaultOutputDevice() -> AudioDeviceID? {
        systemObjectUInt32(selector: kAudioHardwarePropertyDefaultOutputDevice)
            .map { AudioDeviceID($0) }
    }

    func setDefaultOutputDevice(id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &value
        ) == noErr
    }

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

    func setOutputVolumeScalar(id: AudioDeviceID, volume: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    func addDefaultOutputDeviceListener(_ handler: @escaping () -> Void) -> PropertyListenerHandle? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            handler: handler
        )
    }

    func addOutputVolumeListener(id: AudioDeviceID, _ handler: @escaping () -> Void) -> PropertyListenerHandle? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        return addListener(objectID: id, address: address, handler: handler)
    }

    // MARK: - Private helpers

    private func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping () -> Void
    ) -> PropertyListenerHandle? {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID, &mutableAddress, .main, block
        )
        guard status == noErr else { return nil }
        return PropertyListenerHandle(
            objectID: objectID,
            address: address,
            queue: .main,
            block: block
        )
    }

    private func listAllDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private func channelCount(id: AudioDeviceID, scope: AudioScope) -> Int {
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

        let ablPtr = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func buildDevice(id: AudioDeviceID, outputCh: Int) -> AudioDevice? {
        guard let name = cfString(id: id, selector: kAudioDevicePropertyDeviceNameCFString) else {
            return nil
        }
        return AudioDevice(
            id: id,
            name: name,
            uid: cfString(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "",
            manufacturer: cfString(id: id, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? "",
            transport: transportType(id: id),
            inputChannels: channelCount(id: id, scope: .input),
            outputChannels: outputCh,
            sampleRate: nominalSampleRate(id: id)
        )
    }

    private func cfString(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfString) == noErr,
              let result = cfString?.takeRetainedValue() else { return nil }
        return result as String
    }

    private func nominalSampleRate(id: AudioDeviceID) -> Double? {
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

    private func transportType(id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "Other"
        }
    }

    private func systemObjectUInt32(selector: AudioObjectPropertySelector) -> UInt32? {
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
}
