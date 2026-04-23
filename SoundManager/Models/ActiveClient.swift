import Foundation

/// SoundManager 仮想出力デバイスに接続している 1 プロセス (client) の情報。
/// ドライバ側の CopyActiveClients() が返す CFDictionary から構築される。
struct ActiveClient: Identifiable, Hashable {
    let pid: Int32
    let bundleID: String

    /// pid はプロセス単位でユニーク (同一プロセスが複数 client を持つケースは rare)。
    var id: Int32 { pid }
}
