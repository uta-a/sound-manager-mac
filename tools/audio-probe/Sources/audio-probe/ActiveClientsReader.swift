import CoreAudio
import Foundation

// SoundManagerDriver の Shared/SMTypes.h と対応する定数。
// CLI では bridging header が使えないので手動で同期する必要がある。
// 4CC 'smac' = 0x736D6163.
let kSMCustomPropertyActiveClients: AudioObjectPropertySelector = {
    let code = "smac".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return AudioObjectPropertySelector(code)
}()

let kSMClientInfoKey_PID = "pid"
let kSMClientInfoKey_BundleID = "bundleID"

struct ActiveClient {
    let pid: Int32
    let bundleID: String
}

struct ActiveClientsReader {
    /// 指定したデバイスに対して kSMCustomPropertyActiveClients を読み出す。
    /// デバイスがそのプロパティを公開していない (非 SoundManager) 場合は nil を返す。
    static func read(deviceID: AudioDeviceID) -> [ActiveClient]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kSMCustomPropertyActiveClients,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var cfList: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfList)
        guard status == noErr, let list = cfList?.takeRetainedValue() else { return nil }

        guard CFGetTypeID(list) == CFArrayGetTypeID() else { return [] }
        let array = list as! CFArray

        var clients: [ActiveClient] = []
        let count = CFArrayGetCount(array)
        for i in 0..<count {
            guard let rawDict = CFArrayGetValueAtIndex(array, i) else { continue }
            let dict = unsafeBitCast(rawDict, to: CFDictionary.self)

            var pid: Int32 = 0
            if let pidValue = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kSMClientInfoKey_PID as CFString).toOpaque()) {
                let cfNumber = unsafeBitCast(pidValue, to: CFNumber.self)
                CFNumberGetValue(cfNumber, .sInt32Type, &pid)
            }

            var bundleID = ""
            if let bundleValue = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kSMClientInfoKey_BundleID as CFString).toOpaque()) {
                let cfString = unsafeBitCast(bundleValue, to: CFString.self)
                bundleID = cfString as String
            }

            clients.append(ActiveClient(pid: pid, bundleID: bundleID))
        }
        return clients
    }
}
