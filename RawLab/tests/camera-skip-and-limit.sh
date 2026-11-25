#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-camera-skip-limit

ln -s "$ROOT/RawLab/RawLab/Resources/zh-Hans.lproj" "$OUT/zh-Hans.lproj"
ln -s "$ROOT/RawLab/RawLab/Resources/en.lproj" "$OUT/en.lproj"

rawlab_ios_camera_sources CORE_CAMERA_SOURCES core_only
rawlab_ios_compile_sony_ptpip host "$OUT/ptpip"
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -module-cache-path "$OUT/modules" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "${CORE_CAMERA_SOURCES[@]}" \
    "$ROOT/RawLab/tests/CameraSkipAndLimitTests.swift" \
    "$OUT/ptpip"/*.o -lc++ -o "$OUT/tests"

mkdir -p "$OUT/profile"
CFFIXED_USER_HOME="$OUT/profile" "$OUT/tests"

if rawlab_ios_sim_init 2>/dev/null; then
    rawlab_ios_camera_sources FULL_CAMERA_SOURCES full
    rawlabkit_flags typecheck "$OUT/swiftpm" iphonesimulator 0
    rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -typecheck \
        -module-cache-path "$OUT/sim-modules" \
        -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
        -Xcc -I"$ROOT/lutools/include" \
        "${FULL_CAMERA_SOURCES[@]}" \
        "$ROOT/RawLab/tests/CameraSkipAndLimitTests.swift"
    echo "PASS: iOS Simulator SDK typecheck for Camera Core + UI"
fi
