import CoreAudio
import Foundation

let client = AudioObjectClient()

let devices = client.enumerateDevices()
let defaultOutputID = client.getDefaultOutputDevice()
let defaultInputID = client.getDefaultInputDevice()

print("=== Audio Devices (\(devices.count)) ===")
print("")

for id in devices {
    let name = client.getDeviceName(id: id) ?? "<unknown>"
    let uid = client.getDeviceUID(id: id) ?? "<no-uid>"
    let manufacturer = client.getManufacturer(id: id) ?? "<unknown>"
    let inputCh = client.getChannelCount(id: id, scope: .input)
    let outputCh = client.getChannelCount(id: id, scope: .output)
    let transport = client.getTransportType(id: id)
    let sampleRate = client.getNominalSampleRate(id: id).map { String(format: "%.0f Hz", $0) } ?? "?"

    var tags: [String] = []
    if id == defaultOutputID { tags.append("DEFAULT OUT") }
    if id == defaultInputID { tags.append("DEFAULT IN") }
    let tagSuffix = tags.isEmpty ? "" : "  [" + tags.joined(separator: ", ") + "]"

    print("[#\(id)] \(name)\(tagSuffix)")
    print("  UID         : \(uid)")
    print("  Manufacturer: \(manufacturer)")
    print("  Transport   : \(transport)")
    print("  Channels    : in \(inputCh) / out \(outputCh)")
    print("  Sample rate : \(sampleRate)")

    if outputCh > 0, let volume = client.getOutputVolumeScalar(id: id) {
        print("  Output vol  : \(String(format: "%.0f%%", volume * 100))")
    }
    print("")
}

if let outputID = defaultOutputID,
   let outputName = client.getDeviceName(id: outputID) {
    print("=== Default Output ===")
    print("[#\(outputID)] \(outputName)")
    if let volume = client.getOutputVolumeScalar(id: outputID) {
        print("  System volume: \(String(format: "%.0f%%", volume * 100))")
    } else {
        print("  System volume: (not readable on this device)")
    }
}

// SoundManagerDriver が公開する kSMCustomPropertyActiveClients を
// 対応する全デバイス (出力のみ) について読み出す。
print("")
print("=== SoundManager Active Clients (by device) ===")
var foundAny = false
for id in devices {
    guard client.getChannelCount(id: id, scope: .output) > 0 else { continue }
    guard let activeClients = ActiveClientsReader.read(deviceID: id) else { continue }
    foundAny = true
    let name = client.getDeviceName(id: id) ?? "<unknown>"
    print("[#\(id)] \(name): \(activeClients.count) client(s)")
    for c in activeClients {
        let bundle = c.bundleID.isEmpty ? "<no bundle>" : c.bundleID
        print("   pid=\(c.pid)  bundleID=\(bundle)")
    }
}
if !foundAny {
    print("(no device exposes kSMCustomPropertyActiveClients — install SoundManagerDriver to see this section)")
}
