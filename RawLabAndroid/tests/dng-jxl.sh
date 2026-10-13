#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
test "$#" -ge 2 || { echo 'Usage: dng-jxl.sh <ABI CMake build directory> <emulator serial> [external.dng]' >&2; exit 2; }
NATIVE="$1"
SERIAL="$2"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
ABI="$(basename "$NATIVE")"
APK="$ROOT/RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk"
case "$SERIAL" in emulator-*) ;; *) echo 'Use an explicit local emulator serial' >&2; exit 2 ;; esac
test -f "$APK" || { echo 'Build :app:assembleDebug first' >&2; exit 1; }
cmake --build "$NATIVE" --target rawlab_dng_tests --parallel "${JOBS:-4}"
RUNTIME="$(sed -n 's/^CMAKE_RUNTIME_OUTPUT_DIRECTORY:[^=]*=//p' "$NATIVE/CMakeCache.txt")"
LIBRARY="$(sed -n 's/^CMAKE_LIBRARY_OUTPUT_DIRECTORY:[^=]*=//p' "$NATIVE/CMakeCache.txt")"
RUNTIME="${RUNTIME:-$NATIVE}"
LIBRARY="${LIBRARY:-$NATIVE}"
test -f "$RUNTIME/rawlab_dng_tests" && test -f "$LIBRARY/libraw.so" || {
    echo 'Native test executable or LibRaw library is missing' >&2; exit 1;
}
LOCAL="$(mktemp -d /tmp/rawlab-dng-jxl.XXXXXX)"
REMOTE="/data/local/tmp/rawlab-dng-jxl-$$"
trap '"$ADB" -s "$SERIAL" shell rm -rf "$REMOTE" >/dev/null 2>&1 || true; rm -rf "$LOCAL"' EXIT
unzip -p "$APK" "lib/$ABI/libc++_shared.so" > "$LOCAL/libc++_shared.so"
"$ADB" -s "$SERIAL" shell mkdir -p "$REMOTE"
"$ADB" -s "$SERIAL" push "$RUNTIME/rawlab_dng_tests" "$LIBRARY/libraw.so" "$LOCAL/libc++_shared.so" "$REMOTE/" >/dev/null
"$ADB" -s "$SERIAL" push "$ROOT/lutools/tests/fixtures/"*.dng "$ROOT/lutools/tests/fixtures/lenses.xml" "$REMOTE/" >/dev/null
ARGS=(--fixtures "$REMOTE")
if [ "$#" -ge 3 ]; then
    "$ADB" -s "$SERIAL" push "$3" "$REMOTE/external.dng" >/dev/null
    ARGS+=("$REMOTE/external.dng")
fi
"$ADB" -s "$SERIAL" shell chmod 755 "$REMOTE/rawlab_dng_tests"
"$ADB" -s "$SERIAL" shell "TMPDIR=$REMOTE LD_LIBRARY_PATH=$REMOTE $REMOTE/rawlab_dng_tests ${ARGS[*]}"
