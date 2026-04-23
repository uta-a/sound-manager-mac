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
