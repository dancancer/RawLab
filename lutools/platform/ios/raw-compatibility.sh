#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass an arm64 iOS simulator UUID followed by external RAW paths}"
shift
test "$#" -gt 0
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
FRAMEWORK="$ROOT/build-ios/sony2fuji.xcframework/ios-arm64_x86_64-simulator"
HEADERS="$ROOT/build-ios-libraw/0.22.2/install/iphonesimulator-arm64/include"
OUT="${RAWLAB_TEST_OUTPUT:-$(mktemp -d /tmp/rawlab-ios-compatibility.XXXXXX)}"
mkdir -p "$OUT"
bash "$ROOT/platform/ios/verify-framework.sh"
tests=(raw_smoke white_balance_tests)
if [ "${RAWLAB_TEST_GPU:-0}" = 1 ]; then tests+=(acceleration_tests); fi
for name in "${tests[@]}"; do
    xcrun --sdk iphonesimulator clang++ -std=c++17 -O2 \
        -target "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" -isysroot "$SDK" \
        -I "$ROOT/include" -I "$ROOT/src" -I "$HEADERS" \
        "$ROOT/tests/$name.cpp" -F "$FRAMEWORK" -framework sony2fuji \
        -Xlinker -rpath -Xlinker "$FRAMEWORK" -o "$OUT/$name"
done
for input in "$@"; do
    raw="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
    for name in "${tests[@]}"; do
        args=("$raw")
        if [ "$name" = acceleration_tests ]; then
            args+=("$ROOT/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        fi
        xcrun simctl spawn "$DEVICE" "$OUT/$name" "${args[@]}" \
            > "$OUT/$(basename "$input").$name.log" 2>&1
        echo "PASS: $(basename "$input") $name (iOS simulator)"
    done
done
echo "Artifacts: $OUT"
