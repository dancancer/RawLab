#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK}"
SERIAL="${ANDROID_SERIAL:?Set ANDROID_SERIAL to the test device}"
case "$(uname -s)" in
  Darwin) HOST=darwin-x86_64 ;;
  Linux) HOST=linux-x86_64 ;;
  *) printf 'Run this check from macOS or Linux.\n' >&2; exit 1 ;;
esac
NDK="$SDK/ndk/27.2.12479018/toolchains/llvm/prebuilt/$HOST"
ADB=("$SDK/platform-tools/adb" -P "${ADB_SERVER_PORT:-5037}" -s "$SERIAL")
TEMP="$(mktemp -d)"
REMOTE="/data/local/tmp/rawlab-gles-lut-$$"
cleanup() {
  "${ADB[@]}" shell rm -rf "$REMOTE" || true
  rm -rf "$TEMP"
}
trap cleanup EXIT
WRAP=()
for name in glGetIntegeri_v glGetInteger64v glBufferData glBufferSubData glDispatchCompute glMapBufferRange glUnmapBuffer; do
  WRAP+=("-Wl,--wrap=$name")
done
"$NDK/bin/aarch64-linux-android26-clang++" -std=c++17 -O2 -Wall -Wextra \
  -static-libstdc++ -DSONY2FUJI_ENABLE_GLES -I"$ROOT/lutools/include" -I"$ROOT/lutools/src" \
  "$ROOT/RawLabAndroid/tests/gles_lut.cpp" "$ROOT/lutools/src/gpu/gles_lut.cpp" \
  "$ROOT/lutools/src/gpu/lut_gpu.cpp" "$ROOT/lutools/src/core/lut_applicator.cpp" \
  "$ROOT/lutools/src/core/lut_parser.cpp" "${WRAP[@]}" -lEGL -lGLESv3 -o "$TEMP/gles-lut-tests"
"${ADB[@]}" shell mkdir "$REMOTE"
"${ADB[@]}" push "$TEMP/gles-lut-tests" "$REMOTE/"
"${ADB[@]}" push "$ROOT/RawLabMac/Resources/MasterRecipes/samalive_vintage.cube" "$REMOTE/"
MODES=("$@")
if [[ ${#MODES[@]} -eq 0 ]]; then MODES=(large groups block failures high-resolution); fi
for mode in "${MODES[@]}"; do
  case "$mode" in
    large|groups|block|failures|high-resolution) ;;
    *) printf 'Unknown test mode: %s\n' "$mode" >&2; exit 1 ;;
  esac
  "${ADB[@]}" shell "cd '$REMOTE' && ./gles-lut-tests '$mode' samalive_vintage.cube"
done
