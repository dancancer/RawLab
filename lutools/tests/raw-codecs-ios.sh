#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK="${1:-$ROOT/build-ios/sony2fuji.xcframework/ios-arm64_x86_64-simulator/sony2fuji.framework}"
DEVICE="${2:-booted}"
LIBRAW="${3:-$ROOT/build-ios-libraw/0.22.2/sources/LibRaw-0.22.2}"
OUT="$(mktemp -d /tmp/rawlab-raw-codecs-ios.XXXXXX)"
trap 'rm -rf -- "$OUT"' EXIT
test -f "$FRAMEWORK/sony2fuji"
test -f "$LIBRAW/libraw/libraw.h"
FRAMEWORK="$(cd "$FRAMEWORK" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
for name in raw_format sony_arw6 sony_arw6_bounds; do
    xcrun --sdk iphonesimulator clang++ -std=c++17 \
        -target "$(uname -m)-apple-ios18.0-simulator" -isysroot "$SDK" \
        -I "$LIBRAW" -I "$ROOT/src" "$ROOT/tests/${name}_tests.cpp" \
        -DLIBRAW_NODLL "-DRAWLAB_ARW6_SOURCE=\"$LIBRAW/src/decoders/sony_arw6.cpp\"" \
        -F "$(dirname "$FRAMEWORK")" -framework sony2fuji \
        -Wl,-rpath,"$(dirname "$FRAMEWORK")" -o "$OUT/$name"
done
if [ -n "${RAWLAB_TEST_FORMAT_DIRECTORY:-}" ]; then
    xcrun simctl spawn "$DEVICE" "$OUT/raw_format" "$RAWLAB_TEST_FORMAT_DIRECTORY"
else
    xcrun simctl spawn "$DEVICE" "$OUT/raw_format"
fi
if [ -n "${RAWLAB_TEST_SONY_ARW6:-}" ]; then
    xcrun simctl spawn "$DEVICE" "$OUT/sony_arw6" "$RAWLAB_TEST_SONY_ARW6"
else
    xcrun simctl spawn "$DEVICE" "$OUT/sony_arw6"
fi
xcrun simctl spawn "$DEVICE" "$OUT/sony_arw6_bounds"
