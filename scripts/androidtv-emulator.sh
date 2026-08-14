#!/usr/bin/env bash
# Start the Hivefin Android TV emulator and (re)install Jellyfin for Android TV.
#
# Usage:
#   scripts/androidtv-emulator.sh start
#   scripts/androidtv-emulator.sh stop
#   scripts/androidtv-emulator.sh screenshot [path]
#
# Server: http://192.168.1.176:4000
set -euo pipefail

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/platform-tools:$PATH"

AVD_NAME="HivefinTV"
APK="${JELLYFIN_ATV_APK:-/tmp/jellyfin-atv/jellyfin-androidtv-v0.19.9-release.apk}"
HIVEFIN_URL="http://192.168.1.176:4000"

cmd="${1:-start}"

case "$cmd" in
  start)
    if ! adb devices | grep -q 'emulator-.*device'; then
      echo "Starting $AVD_NAME…"
      nohup emulator -avd "$AVD_NAME" \
        -netdelay none -netspeed full -gpu auto \
        -no-snapshot-load -no-snapshot-save -no-boot-anim \
        >/tmp/jellyfin-atv/emulator.log 2>&1 &
      echo $! >/tmp/jellyfin-atv/emulator.pid
    fi
    echo "Waiting for boot…"
    adb wait-for-device
    for i in $(seq 1 90); do
      [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
      sleep 2
    done
    if [ -f "$APK" ]; then
      adb install -r "$APK" || true
    fi
    adb shell am start -n org.jellyfin.androidtv/.ui.startup.StartupActivity || true
    echo "Emulator ready. Hivefin: $HIVEFIN_URL"
    adb devices -l
    ;;
  stop)
    adb emu kill || true
    ;;
  screenshot)
    out="${2:-/tmp/jellyfin-atv/screen.png}"
    mkdir -p "$(dirname "$out")"
    adb exec-out screencap -p > "$out"
    echo "$out"
    ;;
  *)
    echo "usage: $0 start|stop|screenshot [path]" >&2
    exit 1
    ;;
esac
