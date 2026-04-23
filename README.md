# sound-manager-mac

macOS 向けのアプリ単位音量ミキサー。SoundSource (Rogue Amoeba) 相当のコア機能を、Swift + SwiftUI (UI) と C++17 + libASPL (HAL Plugin) で自作する学習プロジェクト。

## 状態

**M0: 技術前提の再整理中** — 実装は未着手、プランのみ確定。

実装計画の詳細は `docs/plan.md` を参照 (M0 完了時に整備)。

## 技術スタック

- UI: Swift 6 + SwiftUI (MenuBarExtra)
- HAL Plugin: C++17 + [libASPL](https://github.com/gavv/libASPL) (MIT)
- 最小 macOS: 14.4 (Sonoma)
- 署名: ad-hoc (学習目的、配布は予定なし)

## 開発ステータス

| マイルストーン | 状態 |
|---------------|-----|
| M0: 技術前提再整理 | 進行中 |
| M1: Swift + CoreAudio 基礎 | 未着手 |
| M2: 最小 HAL Plugin + latency/SR 検証 | 未着手 |
| M3: アプリ検出 + TCC 権限フロー | 未着手 |
| M4: 個別音量調整 + エッジケース対応 | 未着手 |
| v1.1 M5: UI 仕上げ + アクセシビリティ | 未着手 |
| v1.1 M6: 安定性・信頼性仕上げ | 未着手 |

## ビルド方法

M1 以降で整備予定。前提: Xcode 15.3+, macOS 14.4+。

## ライセンス

このプロジェクト本体は [MIT License](./LICENSE)。

## 参考プロジェクトと謝辞

- [libASPL (gavv)](https://github.com/gavv/libASPL) — MIT、HAL Plugin 用 C++17 ラッパ。submodule として採用予定。
- [BackgroundMusic (kyleneideck)](https://github.com/kyleneideck/BackgroundMusic) — **GPL-2.0**、アーキテクチャ/プロパティ設計の参考のみ。**コード直接流用はライセンス伝播を避けるため禁止**。
- [SimplyCoreAudio (rnine)](https://github.com/rnine/SimplyCoreAudio) — Swift CoreAudio ラッパ設計の参考。
- [Apple 公式サンプル "Creating an Audio Server Driver Plug-in"](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) — HAL Plugin の学習リファレンス。
