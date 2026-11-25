#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-camera-originals
rawlab_ios_compile_sony_ptpip host "$OUT/ptpip"
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -module-cache-path "$OUT/modules" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraJPEGProcessing.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraOriginalStore.swift" \
    "$ROOT/RawLab/tests/CameraOriginalStoreTests.swift" \
    "$OUT/ptpip"/*.o -lc++ -o "$OUT/tests"
"$OUT/tests"
bash "$ROOT/RawLab/tests/camera-skip-and-limit.sh"
