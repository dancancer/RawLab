#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-inspection-suite
for source in core/photo_geometry core/inspection_overlay ffi/inspection_c; do
    rawlab_mac_clangxx -std=c++17 -O2 \
        -I "$ROOT/lutools/include" -I "$ROOT/lutools/src" \
        -c "$ROOT/lutools/src/$source.cpp" -o "$OUT/$(basename "$source").o"
done
rawlabnative_flags link "$OUT/swiftpm" macos 0 inspection
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization \
    -DRAWLAB_INSPECTION_NATIVE_ONLY \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacViewingState.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacPhotoViewport.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/HistogramPresentation.swift" \
    "$ROOT/RawLabMac/tests/MacInspectionSuiteTests.swift" \
    "$OUT"/*.o -lc++ \
    -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers -o "$OUT/test"
"$OUT/test"

CORE_BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
DNG_FIXTURE="${RAWLAB_TEST_DNG:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}"
if [ -f "$CORE_BUILD/libsony2fuji_core.a" ] && [ -f "$DNG_FIXTURE" ]; then
    rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/native-test" -- \
        -parse-as-library -D RAWLAB_NATIVE_EDITOR_MODEL \
        "$ROOT/RawLabMac/Sources/Presentation/HistogramPresentation.swift" \
        "$ROOT/RawLabMac/tests/MacInspectionSuiteTests.swift" \
        -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)"
    "$OUT/native-test" "$DNG_FIXTURE"
fi
