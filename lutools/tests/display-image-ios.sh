#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK="${1:-$ROOT/build-ios/sony2fuji.xcframework/ios-arm64_x86_64-simulator/sony2fuji.framework}"
DEVICE="${2:-booted}"
OUT="$(mktemp -d /tmp/rawlab-display-image-ios.XXXXXX)"
trap 'rm -r -- "$OUT"' EXIT
test -f "$FRAMEWORK/sony2fuji"
FRAMEWORK="$(cd "$FRAMEWORK" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun --sdk iphonesimulator clang++ -std=c++17 \
    -target "$ARCH-apple-ios18.0-simulator" -isysroot "$SDK" \
    -I "$ROOT/include" "$ROOT/tests/display_image_tests.cpp" \
    -F "$(dirname "$FRAMEWORK")" -framework sony2fuji \
    -framework CoreFoundation -framework CoreGraphics -framework ImageIO \
    -Wl,-rpath,"$(dirname "$FRAMEWORK")" -o "$OUT/display-image-tests"
if [[ -n "${RAWLAB_TEST_GAIN_MAP:-}" ]]; then
    SIMCTL_CHILD_RAWLAB_TEST_GAIN_MAP="$RAWLAB_TEST_GAIN_MAP" \
        xcrun simctl spawn "$DEVICE" "$OUT/display-image-tests"
else
    xcrun simctl spawn "$DEVICE" "$OUT/display-image-tests"
fi
