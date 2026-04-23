import Foundation

/// TCC (Transparency, Consent, Control) 権限の状態。
/// M3 段階ではどの権限も要求していないので全て `.notRequired` を返す。
/// M4 で仮想入力ストリーム読取 (LoopbackEngine) や Process Tap API を使う時点で、
/// ここに実際の NSAudioCaptureUsageDescription チェックなどが入る。
enum TCCPermissionStatus: Equatable {
    /// 現バージョンではこの権限を使用しない (= UI 的にも要求しない)
    case notRequired
    /// ユーザーがまだ許可・拒否していない
    case notDetermined
    /// ユーザーが許可した
    case granted
    /// ユーザーが拒否した
    case denied
}

/// アプリが将来必要になる可能性のある TCC 権限をまとめて管理するスタブ。
/// 現段階では枠組みのみだが、M4 以降の拡張で使用部位ごとに `.notRequired` から
/// 実際のチェックに置き換える。
@MainActor
final class PermissionChecker {
    /// Process Tap API / 仮想入力ストリーム経由の system audio capture 権限。
    /// 実装予定: NSAudioCaptureUsageDescription + `AVCaptureDevice.authorizationStatus(for: .audio)` 等
    func audioCaptureStatus() -> TCCPermissionStatus {
        .notRequired
    }

    /// 現時点で全ての必須権限が満たされているか (UI で onboarding を出すかの判定に使う)
    func allRequiredGranted() -> Bool {
        switch audioCaptureStatus() {
        case .granted, .notRequired:
            return true
        case .notDetermined, .denied:
            return false
        }
    }

    /// System Settings > Privacy & Security の該当ページを開く URL。
    /// M4 で実権限を要求する際にボタンから叩く。
    static func systemSettingsURL(for permission: String = "Microphone") -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(permission)")
    }
}
