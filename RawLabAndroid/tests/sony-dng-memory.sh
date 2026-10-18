#!/bin/bash
set -euo pipefail
ROOT="${1:?Pass the tested repository root}"
DEVICE="${2:?Pass the explicit device serial}"
LABEL="${3:?Pass a unique run label}"
GPU="${4:-cpu}"
FORMATS="${5:-dng,png,jpg}"
EDGE="${6:-0}"
REFERENCE="${7:-true}"
PACKAGE="com.rawlab.android.sonymemory"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
APKANALYZER="$SDK/cmdline-tools/latest/bin/apkanalyzer"
APP_APK="${RAWLAB_MEMORY_APP_APK:-$ROOT/RawLabAndroid/app/build/intermediates/apk/debug/app-debug.apk}"
TEST_APK="${RAWLAB_MEMORY_TEST_APK:-$ROOT/RawLabAndroid/app/build/intermediates/apk/androidTest/debug/app-debug-androidTest.apk}"
if [ "$("$APKANALYZER" manifest application-id "$APP_APK")" != "$PACKAGE" ] || \
    [ "$("$APKANALYZER" manifest application-id "$TEST_APK")" != "$PACKAGE.test" ]; then
    printf '%s\n' 'Refusing non-isolated APKs; build with -I tests/sony-dng-memory.gradle' >&2
    exit 2
fi
OUT="$ROOT/build/sony-dng-memory/runs/$LABEL"
mkdir -p "$OUT"
printf 'device=%s\npackage=%s\ngpu=%s\nformats=%s\nexport_edge=%s\nreference=%s\nprofile=%s\nbudget=%s\nrss_budget=%s\n' \
    "$DEVICE" "$PACKAGE" "$GPU" "$FORMATS" "$EDGE" "$REFERENCE" "${RAWLAB_MEMORY_PROFILE:-all}" \
    "${RAWLAB_MEMORY_BUDGET:-unset}" "${RAWLAB_MEMORY_RSS_BUDGET:-unset}" > "$OUT/parameters.txt"
shasum -a 256 "$APP_APK" "$TEST_APK" > "$OUT/apk.sha256"
"$ADB" -s "$DEVICE" wait-for-device
"$ADB" -s "$DEVICE" shell cat /proc/meminfo > "$OUT/meminfo-before.txt"
"$ADB" -s "$DEVICE" shell getprop > "$OUT/device-properties.txt"
"$ADB" -s "$DEVICE" shell am force-stop "$PACKAGE"
"$ADB" -s "$DEVICE" install -r -t "$APP_APK"
"$ADB" -s "$DEVICE" install -r -t "$TEST_APK"
"$ADB" -s "$DEVICE" logcat -T 1 -v epoch RawLabDngMemory:I TestRunner:I lmkd:I lowmemorykiller:I ActivityManager:I '*:S' > "$OUT/logcat.log" 2>&1 &
LOG_PID=$!
stop_log() { kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; }
trap stop_log EXIT INT TERM
EXTRA=(-e dngMemoryProfile "${RAWLAB_MEMORY_PROFILE:-all}")
if [ -n "${RAWLAB_MEMORY_BUDGET:-}" ]; then EXTRA+=(-e dngMemoryBudgetBytes "$RAWLAB_MEMORY_BUDGET"); fi
if [ -n "${RAWLAB_MEMORY_RSS_BUDGET:-}" ]; then EXTRA+=(-e dngMemoryRssBudgetBytes "$RAWLAB_MEMORY_RSS_BUDGET"); fi
"$ADB" -s "$DEVICE" shell am instrument -w -r \
    -e class com.rawlab.android.engine.memory.NativeDngMemoryTest#originalSizeExportsAfterViewportMatchIndependentFinal \
    -e dngMemoryLabel "$LABEL" -e dngMemoryGpu "$GPU" -e dngMemoryFormats "$FORMATS" \
    -e dngMemoryExportEdge "$EDGE" -e dngMemoryReference "$REFERENCE" "${EXTRA[@]}" \
    "$PACKAGE.test/androidx.test.runner.AndroidJUnitRunner" | tee "$OUT/instrumentation.log"
"$ADB" -s "$DEVICE" shell dumpsys meminfo "$PACKAGE" > "$OUT/meminfo-after.txt"
"$ADB" -s "$DEVICE" exec-out run-as "$PACKAGE" tar -cf - -C "files/sony-dng-memory/$LABEL" . > "$OUT/outputs.tar"
tar -xf "$OUT/outputs.tar" -C "$OUT"
echo "Artifacts: $OUT"
rg -q '^OK \(1 test\)' "$OUT/instrumentation.log"
