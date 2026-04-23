import CoreAudio
import SwiftUI

struct MenuBarView: View {
    @State private var vm = MixerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            deviceSection

            volumeSection

            Divider()

            activeClientsSection

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
            Text("SoundManager")
                .font(.headline)
            Spacer()
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("出力デバイス")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("出力デバイス", selection: Binding<AudioDeviceID>(
                get: { vm.selectedOutputID ?? 0 },
                set: { newValue in
                    if newValue != 0 { vm.selectedOutputID = newValue }
                }
            )) {
                ForEach(vm.outputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("システム音量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.volumeIsReadable {
                    Text(String(format: "%.0f%%", vm.volume * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("(このデバイスでは調整不可)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(
                    value: Binding<Double>(
                        get: { vm.volume },
                        set: { vm.volume = $0 }
                    ),
                    in: 0...1
                )
                .disabled(!vm.volumeIsReadable)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var activeClientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SoundManager クライアント")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.activeClients.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if vm.soundManagerDeviceID == nil {
                Text("SoundManagerDriver が未インストールです")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if vm.activeClients.isEmpty {
                Text("(接続中のクライアントなし)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(vm.activeClients.prefix(6)) { c in
                    HStack(spacing: 6) {
                        Text(c.bundleID.isEmpty ? "pid \(c.pid)" : c.bundleID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("#\(c.pid)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if vm.activeClients.count > 6 {
                    Text("…他 \(vm.activeClients.count - 6) 件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("更新") { vm.refresh() }
                .buttonStyle(.borderless)
            Spacer()
            Button("SoundManager を終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
    }
}

#Preview {
    MenuBarView()
}
