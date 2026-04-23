import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                Text("SoundManager")
                    .font(.headline)
                Spacer()
            }

            Divider()

            Text("M1b skeleton")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("MenuBarExtra ライフサイクルの起動確認用。\nM1c でデバイス一覧とシステム音量スライダを追加予定。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("SoundManager を終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }
}

#Preview {
    MenuBarView()
}
