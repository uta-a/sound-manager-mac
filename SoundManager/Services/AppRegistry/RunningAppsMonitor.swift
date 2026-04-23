import AppKit
import Foundation

/// `NSWorkspace.runningApplications` を観測して、bundleID → AppInfo のマップを公開する。
/// アプリ起動/終了の notification で自動更新し、onChange コールバックで購読側に通知する。
@MainActor
final class RunningAppsMonitor {
    struct AppInfo {
        let bundleID: String
        let displayName: String
        let icon: NSImage?
    }

    private(set) var appsByBundleID: [String: AppInfo] = [:]

    /// appsByBundleID の内容が変化したタイミングで呼ばれる。
    /// MixerViewModel が設定して activeApps 再構築をトリガする。
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        )
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    func refresh() {
        var map: [String: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            map[bundleID] = AppInfo(
                bundleID: bundleID,
                displayName: app.localizedName ?? bundleID,
                icon: app.icon
            )
        }
        appsByBundleID = map
        onChange?()
    }
}
