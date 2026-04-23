#!/bin/bash
#
# SoundManagerDriver を /Library/Audio/Plug-Ins/HAL/ から削除し、
# coreaudiod を再起動する。
#
# 使い方:
#   sudo ./scripts/uninstall-driver.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: このスクリプトは sudo で実行してください" >&2
    exit 1
fi

INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET="${INSTALL_DIR}/SoundManagerDriver.driver"

if [[ -d "${TARGET}" ]]; then
    echo "-- Removing ${TARGET}"
    rm -rf "${TARGET}"
else
    echo "-- ${TARGET} is already absent"
fi

echo "-- Restarting coreaudiod"
if ! launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "   launchctl kickstart failed (SIP), falling back to killall -9"
    killall -9 coreaudiod
fi

echo "-- Done"
