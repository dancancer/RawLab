#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  SDK="${ANDROID_HOME:?Set ANDROID_NDK_HOME or ANDROID_HOME to locate the Android NDK}"
  if [[ -f "$SDK/ndk/27.2.12479018/build/cmake/android.toolchain.cmake" ]]; then
    NDK="$SDK/ndk/27.2.12479018"
  else
    NDK="$(
      for d in "$SDK/ndk/"*/; do
        if [[ -f "${d}build/cmake/android.toolchain.cmake" ]]; then
          printf '%s\n' "${d%/}"
        fi
      done | sort -V | tail -n 1 || true
    )"
  fi
fi
if [[ -z "$NDK" || ! -f "$NDK/build/cmake/android.toolchain.cmake" ]]; then
  printf 'Android NDK toolchain not found (checked ANDROID_NDK_HOME and ANDROID_HOME/ndk)\n' >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-android-ndk-compile.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

JOBS="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
cmake -S "$ROOT/RawLabAndroid/tests/ndk-targets" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DANDROID_STL=c++_shared \
  "$@"

cmake --build "$BUILD_DIR" --parallel "$JOBS"
