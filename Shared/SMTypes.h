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

#endif  // SOUND_MANAGER_SHARED_SMTYPES_H
