import AppKit
import Foundation

/// UI に表示する単位。複数の ActiveClient (helper プロセス含む) が bundleID で統合された結果。
struct ActiveApp: Identifiable {
    let bundleID: String
    let displayName: String
    let icon: NSImage?
    let pids: [Int32]

    var id: String { bundleID }
}

extension ActiveApp: Equatable {
    static func == (lhs: ActiveApp, rhs: ActiveApp) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.displayName == rhs.displayName
            && lhs.pids == rhs.pids
    }
}
