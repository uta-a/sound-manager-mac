# Signal Flow

SoundManager のオーディオ信号経路とプロセス間通信の全体図。プランの「コアアーキテクチャ」節を実装者目線で補足する。

## 方針

**BGM 方式**: SoundManager 仮想デバイスを macOS の**唯一の既定出力**にして音を集約し、ドライバ内部で PID 別に gain 処理してから、自前のループバック経路で実出力デバイスへ流す。

## 全体シーケンス図 (通常再生)

```
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐ ┌──────────────┐ ┌────────────┐
│ Music.app│ │ Chrome   │ │ Zoom     │ │ coreaudiod       │ │ SoundManager │ │ 実出力     │
│          │ │ helper   │ │          │ │ + SM Driver      │ │ .app         │ │ (AirPods/  │
│          │ │          │ │          │ │ (C++17/libASPL)  │ │ (Swift)      │ │  USB DAC)  │
└────┬─────┘ └────┬─────┘ └────┬─────┘ └────────┬─────────┘ └──────┬───────┘ └──────┬─────┘
     │            │            │                │                  │                │
     │ PCM write  │            │                │                  │                │
     │ (PID=Music)│            │                │                  │                │
     │───────────────────────────────────────▶│                  │                │
     │            │ PCM write (PID=Chrome)     │                  │                │
     │            │──────────────────────────▶│                  │                │
     │            │            │ PCM write     │                  │                │
     │            │            │──────────────▶│                  │                │
     │            │            │                │                  │                │
     │            │   [PID 別 gain 乗算]        │                  │                │
     │            │   [ミックス → ring buf]     │                  │                │
     │            │            │                │                  │                │
     │            │            │                │ loopback stream  │                │
     │            │            │                │──────────────────▶                │
     │            │            │                │                  │ IOProc read    │
     │            │            │                │                  │ + drift 検出   │
     │            │            │                │                  │ + resampling   │
     │            │            │                │                  │                │
     │            │            │                │                  │ PCM write      │
     │            │            │                │                  │───────────────▶│
     │            │            │                │                  │                │ 再生
```

## 制御プレーン (音量変更時)

```
┌─────────────────┐                    ┌──────────────────────┐
│ SoundManager.app│                    │ SM Driver            │
│ (SwiftUI)       │                    │ (C++17/libASPL)      │
└────────┬────────┘                    └──────────┬───────────┘
         │                                        │
         │ ユーザーがスライダ操作                │
         │                                        │
         │ AudioObjectSetPropertyData             │
         │ (kSMCustomPropertyAppVolumes)          │
         │───────────────────────────────────────▶│
         │                                        │
         │                          [内部 gain テーブル更新]
         │                          [次の ProcessOutput で適用]
         │                                        │
         │   AudioObjectAddPropertyListenerBlock  │
         │   (変更通知)                           │
         │◀───────────────────────────────────────│
         │                                        │
         │ UI に反映 (他の SoundManager インスタンスと同期)
```

## 仮想デバイス内部構造 (SMDevice)

```
SoundManager 仮想出力デバイス
  │
  ├─ Available stream formats
  │    ├─ 44.1 kHz / 2ch / Float32 Non-Interleaved
  │    ├─ 48 kHz  / 2ch / Float32 Non-Interleaved
  │    └─ 96 kHz  / 2ch / Float32 Non-Interleaved
  │
  ├─ Output stream (アプリから受ける)
  │    │
  │    ├─ Client registry (SMClientMap)
  │    │    ├─ PID: 1234, bundleID: com.apple.Music,  gain: 1.0, muted: false
  │    │    ├─ PID: 5678, bundleID: com.google.Chrome, gain: 0.5, muted: false
  │    │    └─ PID: 9012, bundleID: us.zoom.xos,      gain: 0.8, muted: false
  │    │
  │    └─ DSP pipeline (SMGainProcessor)
  │         ├─ per-client: output[n] = input[n] * gain
  │         ├─ mix: Σ per-client outputs
  │         ├─ soft clip: tanh(mixed * headroom)
  │         └─ limiter: attack 1ms, release 50ms, -1dBFS
  │
  └─ Input stream (ループバック、SoundManager.app が読む)
       │
       └─ Ring buffer (DSP pipeline の出力をコピー)
```

## 起動・停止シーケンス

### 起動

1. SoundManager.app 起動
2. `PermissionChecker` で TCC 権限を確認
3. 未許可なら `OnboardingView` を表示して System Preferences へ誘導
4. `SoundManagerDeviceFinder` でドライバの AudioObjectID を取得
   - 見つからなければ「ドライバが未インストール」UI を表示
5. カスタムプロパティ `kSMCustomPropertyActiveClients` / `kSMCustomPropertyAppVolumes` のリスナー登録
6. `LoopbackEngine` 起動:
   - ドライバのループバック入力ストリームを入力に
   - ユーザー選択 (または既定) の実出力デバイスを出力に
   - CoreAudio `AudioDeviceIOProc` 経由で PCM 受け渡し
7. UserDefaults から永続化済みの per-app volume を読み、ドライバに書き戻し
8. menu bar のアイコンをアクティブ状態に

### 停止

1. `LoopbackEngine` 停止 (IOProc 停止 + デバイス解放)
2. カスタムプロパティリスナー解除
3. 永続化が必要な状態があれば UserDefaults に flush

### sleep → wake 復帰

1. `kAudioHardwarePropertyDefaultOutputDevice` の change listener で検知
2. 実出力デバイスが変わっていたら LoopbackEngine を再初期化
3. ドライバが消えていれば (macOS update 後など) 再インストール案内

## 注意点

- **既定出力が SoundManager になっていない間は、他アプリの音は SoundManager ドライバに来ない**。このため SoundManager.app は起動時に「既定出力を SoundManager に切り替える」操作をユーザーに促す (自動切替オプションあり)。
- ループバック経路はユーザースペース経由なので**最低 10-20ms の追加 latency** が乗る。目標は end-to-end < 30ms。会議・ゲーム用途は M2 で latency 計測した結果で判断する。
- 仮想デバイスのサンプルレートと実出力のサンプルレートが異なる場合は `AudioConverter` で resampling する。クロックドリフトは 10 秒ごとに監視して 10ppm を超えたらログ警告する。

## 信号に関係しないが関連する経路

### ドライバインストール

```
scripts/install-driver.sh
  │
  ├─ xcodebuild -scheme SoundManagerDriver -configuration Release
  ├─ codesign --sign - SoundManagerDriver.driver  (ad-hoc)
  ├─ sudo cp -R SoundManagerDriver.driver /Library/Audio/Plug-Ins/HAL/
  └─ sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

### ドライバアンインストール

```
scripts/uninstall-driver.sh
  │
  ├─ sudo rm -rf /Library/Audio/Plug-Ins/HAL/SoundManagerDriver.driver
  └─ sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```
