#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-inspection-suite
for source in core/photo_geometry core/inspection_overlay ffi/inspection_c; do
    clang++ -std=c++17 -O2 \
        -isysroot "$RAWLAB_IOS_HOST_SDK" -target "$RAWLAB_IOS_HOST_TARGET" \
        -I "$ROOT/lutools/include" -I "$ROOT/lutools/src" \
        -c "$ROOT/lutools/src/$source.cpp" -o "$OUT/$(basename "$source").o"
done
rawlabnative_flags link "$OUT/swiftpm" macos 0 inspection
rawlab_ios_host_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" \
    -DRAWLAB_INSPECTION_NATIVE_ONLY \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorCoordinator.swift" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorToolDraft.swift" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" \
    "$ROOT/RawLab/tests/IOSInspectionSuiteTests.swift" \
    "$OUT"/*.o -lc++ \
    -framework SwiftUI -framework PhotosUI -framework UniformTypeIdentifiers -framework ImageIO \
    -o "$OUT/ios-inspection-suite-tests"
"$OUT/ios-inspection-suite-tests"
