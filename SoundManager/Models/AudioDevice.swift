import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let manufacturer: String
    let transport: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double?

    var isOutputCapable: Bool { outputChannels > 0 }
    var isInputCapable: Bool { inputChannels > 0 }
}
