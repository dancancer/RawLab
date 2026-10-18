#!/bin/bash
set -euo pipefail
ROOT="${1:?Pass the tested repository root}"
LABEL="${2:?Pass a unique run label}"
WARM="${3:-false}"
OUT="${4:-$(mktemp -d /tmp/rawlab-android-memory.XXXXXX)}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
DEVICE="${ANDROID_SERIAL:-emulator-5580}"
RECOMPUTE="${5:-false}"
EXTRA=()
if [ -n "${6:-}" ]; then EXTRA=(-e memoryBudgetBytes "$6"); fi
if [ -n "${7:-}" ]; then EXTRA+=(-e memoryExposureMode "$7"); fi
mkdir -p "$OUT"
"$ADB" -s "$DEVICE" wait-for-device
until "$ADB" -s "$DEVICE" shell getprop sys.boot_completed | tr -d '\r' | rg -q '^1$'; do sleep 1; done
until "$ADB" -s "$DEVICE" shell dumpsys user | rg -q 'State: RUNNING_UNLOCKED'; do sleep 1; done
"$ADB" -s "$DEVICE" shell am force-stop com.rawlab.android
"$ADB" -s "$DEVICE" install -r -t "$ROOT/RawLabAndroid/app/build/intermediates/apk/debug/app-debug.apk"
"$ADB" -s "$DEVICE" install -r -t "$ROOT/RawLabAndroid/app/build/intermediates/apk/androidTest/debug/app-debug-androidTest.apk"
"$ADB" -s "$DEVICE" logcat -c
"$ADB" -s "$DEVICE" shell cat /proc/meminfo > "$OUT/meminfo.txt"
"$ADB" -s "$DEVICE" shell am instrument -w -r \
    -e class com.rawlab.android.engine.memory.NativeMemoryTest#nativeDenoiseExportsFitLimitedMemory \
    -e memoryLabel "$LABEL" -e memoryWarmDenoise "$WARM" -e memoryRecomputeDenoise "$RECOMPUTE" \
    "${EXTRA[@]}" \
    com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner | tee "$OUT/instrumentation.log"
"$ADB" -s "$DEVICE" logcat -d -s RawLabMemory TestRunner lowmemorykiller > "$OUT/logcat.log"
"$ADB" -s "$DEVICE" exec-out run-as com.rawlab.android tar -cf - -C files/memory-probe . > "$OUT/outputs.tar"
tar -xf "$OUT/outputs.tar" -C "$OUT"
echo "Artifacts: $OUT"
rg -q '^OK \(1 test\)' "$OUT/instrumentation.log"
