# audio-probe

Swift CLI で CoreAudio の AudioObject API を叩き、システムのオーディオデバイス一覧と音量情報を列挙する診断ツール。

## 目的

- M1a の学習目標: `AudioObjectGetPropertyData` / `AudioObjectGetPropertyDataSize` の Swift ラッパを書く
- `UnsafeMutablePointer`, `MemoryLayout`, `Unmanaged<CFString>` の体感
- 将来の `SoundManager.app` の `Services/CoreAudio/AudioObjectClient.swift` の雛形

## ビルド & 実行

```bash
cd tools/audio-probe
swift build
swift run
```

## 出力例

- 全オーディオデバイスの名前、UID、manufacturer、transport、チャンネル構成、サンプルレート、出力音量
- デフォルト出力/入力デバイスのハイライト
- システム全体の音量 (デフォルト出力の master volume)

## 実装ファイル

- `Sources/audio-probe/AudioObjectClient.swift` — CoreAudio AudioObject の薄いラッパ
- `Sources/audio-probe/main.swift` — デバイス列挙 + 情報表示の entry point
