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
