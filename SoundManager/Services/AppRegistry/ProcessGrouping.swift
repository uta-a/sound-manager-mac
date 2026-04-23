import AppKit
import Foundation

/// bundleID の正規化・システム除外・ActiveApp ビルドを行う純関数群。
/// 副作用なし、NSWorkspace 非依存。ユニットテスト対象。
enum ProcessGrouping {
    /// システム由来で UI に出すべきでない bundleID 接頭辞。
    /// SoundManager デバイスを購読している coreaudiod や controlcenter などを除外する。
    static let systemBundlePrefixes: [String] = [
        "com.apple.audio.",
        "com.apple.Core-Audio",
        "com.apple.CoreSpeech",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.mediaremoted",
        "com.apple.quicklook.",
        "com.apple.PowerChime",
        "com.apple.avconferenced",
        "com.apple.systemsoundserverd",
    ]

    static let systemBundleExact: Set<String> = [
        "systemsoundserverd",
    ]

    /// Helper プロセスの bundleID を親アプリの bundleID に正規化する。
    /// 例:
    ///   "com.google.Chrome.helper" → "com.google.Chrome"
    ///   "com.google.Chrome.helper.Renderer" → "com.google.Chrome"
    ///   "com.hnc.Discord.helper" → "com.hnc.Discord"
    /// `.helper` を含まない bundleID はそのまま返す。
    static func normalize(_ bundleID: String) -> String {
        if let range = bundleID.range(of: ".helper") {
            return String(bundleID[..<range.lowerBound])
        }
        return bundleID
    }

    /// 指定 bundleID がシステムサービスかどうか (UI では除外対象)。
    static func isSystemBundle(_ bundleID: String) -> Bool {
        if systemBundleExact.contains(bundleID) {
            return true
        }
        return systemBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// 生の ActiveClient リストを正規化・除外・グルーピングして UI 用 ActiveApp 配列に変換する。
    /// `appInfoForBundleID` は NSWorkspace などからの情報取得をテストで差し替え可能にするためのクロージャ。
    /// bundleID が解決できない場合は displayName = bundleID として残す (完全な除外はしない)。
    static func buildActiveApps(
        from clients: [ActiveClient],
        appInfoForBundleID: (String) -> (displayName: String, icon: NSImage?)?
    ) -> [ActiveApp] {
        var byBundleID: [String: (displayName: String, icon: NSImage?, pids: [Int32])] = [:]

        for client in clients {
            let normalized = normalize(client.bundleID)
            if normalized.isEmpty { continue }
            if isSystemBundle(normalized) { continue }

            let info = appInfoForBundleID(normalized)
            let displayName = info?.displayName ?? normalized
            let icon = info?.icon

            if var existing = byBundleID[normalized] {
                existing.pids.append(client.pid)
                byBundleID[normalized] = existing
            } else {
                byBundleID[normalized] = (displayName, icon, [client.pid])
            }
        }

        return byBundleID.map { bundleID, value in
            ActiveApp(
                bundleID: bundleID,
                displayName: value.displayName,
                icon: value.icon,
                pids: value.pids.sorted()
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
