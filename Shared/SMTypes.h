// SoundManager - SMTypes.h
//
// SoundManagerDriver (C++17) と SoundManager.app (Swift via bridging header)
// で共有する CoreAudio カスタムプロパティ selector と CFDictionary キー。
//
// 本ファイルは C header として書かれており、extern "C" 不要 (defines/const のみ)。

#ifndef SOUND_MANAGER_SHARED_SMTYPES_H
#define SOUND_MANAGER_SHARED_SMTYPES_H

#include <CoreAudio/AudioHardwareBase.h>

// "smac" = SoundManager Active Clients.
// CFArray<CFDictionary> を返す read-only プロパティ。
// 各 CFDictionary は { "pid": CFNumber (Int32), "bundleID": CFString } を持つ。
// 現在 SoundManager 仮想出力デバイスに PCM を書き込んでいる client 一覧。
static const AudioObjectPropertySelector kSMCustomPropertyActiveClients = 'smac';

// CFDictionary keys used inside the kSMCustomPropertyActiveClients array.
#define kSMClientInfoKey_PID      "pid"
#define kSMClientInfoKey_BundleID "bundleID"

// "smav" = SoundManager App Volumes.
// CFArray<CFDictionary> の read/write プロパティ。
// 各 CFDictionary は { "bundleID": CFString, "gain": CFNumber (Float32) } を持つ。
// gain は線形スカラ (0.0 = ミュート、1.0 = unity、それ以上はブースト)。
// UI がこのプロパティに書き込むと driver は対応する bundleID の
// OnProcessClientOutput バッファに gain を乗算する。
static const AudioObjectPropertySelector kSMCustomPropertyAppVolumes = 'smav';

// CFDictionary keys used inside the kSMCustomPropertyAppVolumes array.
#define kSMAppVolumeKey_BundleID "bundleID"
#define kSMAppVolumeKey_Gain     "gain"

#endif  // SOUND_MANAGER_SHARED_SMTYPES_H
