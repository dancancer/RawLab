#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass a booted or available arm64 simulator UUID, optionally followed by a DNG path}"
EXTERNAL="${2:-}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
FRAMEWORK="${RAWLAB_IOS_FRAMEWORK:-$ROOT/build-ios/sony2fuji.xcframework/ios-arm64_x86_64-simulator}"
OUTPUT="${RAWLAB_TEST_OUTPUT:-$ROOT/build-ios/dng-jxl-$DEVICE}"
STAGE="${RAWLAB_SIM_FIXTURES:-$OUTPUT/fixtures}"
BINARY="$OUTPUT/dng_jxl_tests"
LOG="$OUTPUT/dng-jxl.log"
BOOTED_BY_SCRIPT=0

test -f "$FRAMEWORK/sony2fuji.framework/sony2fuji"
mkdir -p "$OUTPUT" "$STAGE/tmp"

cleanup() {
    if [ "$BOOTED_BY_SCRIPT" -eq 1 ]; then
        xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    fi
    if [ "${RAWLAB_KEEP_TEMP:-0}" != 1 ] && [ -z "${RAWLAB_SIM_FIXTURES:-}" ]; then
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

device_state="$(xcrun simctl list devices | grep -F "($DEVICE)" || true)"
if [[ "$device_state" != *"(Booted)"* ]]; then
    xcrun simctl boot "$DEVICE"
    BOOTED_BY_SCRIPT=1
fi
xcrun simctl bootstatus "$DEVICE" -b

fixtures=(
    linear-jxl.dng
    linear-uncompressed.dng
    linear-jxl-gain.dng
    linear-doubled.dng
    linear-jxl-stage1.dng
    linear-halved.dng
    linear-jxl-crop-gain.dng
    linear-crop-doubled.dng
    linear-jxl-required-unknown.dng
    linear-jxl-default-crop-gain.dng
    linear-default-crop-doubled.dng
    linear-jxl-channel-levels.dng
    linear-channel-levels.dng
    linear-normalized.dng
    linear-jxl-lens.dng
    linear-lens.dng
    linear-jxl-stage3-lens.dng
    lenses.xml
)
for fixture in "${fixtures[@]}"; do
    cp "$ROOT/tests/fixtures/$fixture" "$STAGE/$fixture"
done

external_copy=""
if [ -n "$EXTERNAL" ]; then
    test -f "$EXTERNAL"
    external_copy="$STAGE/external-$(basename "$EXTERNAL")"
    cp "$EXTERNAL" "$external_copy"
fi

test_define="-DTEST_FIXTURE_DIR=\"$ROOT/tests/fixtures\""
core="$ROOT/build-ios-libraw/0.22.2/core-iphonesimulator-arm64"
dng_source="$(sed -n 's/^FETCHCONTENT_SOURCE_DIR_RAWLAB_DNG_SOURCE:[^=]*=//p' "$core/CMakeCache.txt")"
dng_source="${dng_source:-$core/_deps/rawlab_dng_source-src}"
dng_headers="${RAWLAB_DNGSDK_HEADERS:-$dng_source/dng_sdk/source}"
test -f "$dng_headers/dng_memory.h"
xcrun --sdk iphonesimulator clang++ -std=c++17 -O2 \
    -target "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" -isysroot "$SDK" \
    -I "$ROOT/include" -I "$dng_headers" "$test_define" \
    -DSONY2FUJI_ENABLE_DNGSDK -DSONY2FUJI_ENABLE_LENSFUN -DqDNGThreadSafe=1 -DqiPhone=1 -DqiPhoneSimulator=1 \
    "$ROOT/tests/dng_jxl_tests.cpp" -F "$FRAMEWORK" -framework sony2fuji \
    -Xlinker -rpath -Xlinker "$FRAMEWORK" -o "$BINARY"

args=(--fixtures "$STAGE")
if [ -n "$external_copy" ]; then
    args+=("$external_copy")
fi

echo "Running DNG JPEG XL regression on simulator $DEVICE"
echo "Fixtures: $STAGE"
echo "Log: $LOG"
SIMCTL_CHILD_TMPDIR="$STAGE/tmp" xcrun simctl spawn "$DEVICE" "$BINARY" "${args[@]}" 2>&1 | tee "$LOG"
