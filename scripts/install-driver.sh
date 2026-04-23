#!/bin/bash
#
# SoundManagerDriver を /Library/Audio/Plug-Ins/HAL/ にインストールし、
# coreaudiod を再起動する。開発用 (ad-hoc 署名前提)。
#
# 使い方:
#   sudo ./scripts/install-driver.sh
#
# 前提:
#   ./SoundManagerDriver/build/SoundManagerDriver.driver が既にビルド済みであること
#   (cd SoundManagerDriver && cmake -B build -DCODESIGN_ID=- && cmake --build build)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: このスクリプトは sudo で実行してください" >&2
    exit 1
fi

# プロジェクトルートへ cd
cd "$(dirname "$0")/.."

DRIVER_SRC="${PWD}/SoundManagerDriver/build/SoundManagerDriver.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ ! -d "${DRIVER_SRC}" ]]; then
    echo "error: driver bundle が見つかりません: ${DRIVER_SRC}" >&2
    echo "hint: まず 'cd SoundManagerDriver && cmake -B build -DCODESIGN_ID=- && cmake --build build' を実行してください" >&2
    exit 1
fi

echo "-- Installing SoundManagerDriver.driver"
rm -rf "${INSTALL_DIR}/SoundManagerDriver.driver"
cp -fr "${DRIVER_SRC}" "${INSTALL_DIR}/"

echo "-- Restarting coreaudiod"
# macOS 26 (Tahoe) SIP 下では launchctl kickstart が拒否されるので killall にフォールバック
if ! launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "   launchctl kickstart failed (SIP), falling back to killall -9"
    killall -9 coreaudiod
fi

echo "-- Done"
echo ""
echo "検証: 'system_profiler SPAudioDataType | grep SoundManager' で認識を確認できます"
