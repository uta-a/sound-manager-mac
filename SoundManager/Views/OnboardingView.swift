import SwiftUI

/// アプリのセットアップ/権限状況を説明するウィンドウ。
/// menu bar の「セットアップ」ボタンから開く。M3c 段階では主にドライバ導入手順と
/// 将来の権限について説明する静的ドキュメントとして機能する。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    private let checker = PermissionChecker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            driverSection
            Divider()
            permissionsSection
            Divider()
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("SoundManager セットアップ")
                    .font(.title2.weight(.semibold))
                Text("macOS 向けアプリ単位の音量ミキサー")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var driverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1. オーディオドライバのインストール", systemImage: "1.circle.fill")
                .font(.subheadline.weight(.semibold))

            Text("アプリ単位で音量を制御するには、付属の `SoundManagerDriver.driver` をシステムに配置する必要があります。プロジェクトルートで以下を実行してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("sudo ./scripts/install-driver.sh")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            Text("インストール後に menu bar の出力デバイス Picker に “SoundManager” が現れ、既定出力に切り替えると再生中のアプリだけが一覧に並びます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("2. 権限 (将来のバージョンで要求)", systemImage: "2.circle.fill")
                .font(.subheadline.weight(.semibold))

            permissionRow(
                title: "システムオーディオキャプチャ",
                description: "M4 以降の版で SoundManager のループバック入力から音声を読み出す際に必要になる予定です。現バージョンでは要求しません。",
                status: checker.audioCaptureStatus()
            )
        }
    }

    private func permissionRow(title: String, description: String, status: TCCPermissionStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(status)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: TCCPermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .notRequired:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    OnboardingView()
}
