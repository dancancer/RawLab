#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-inspection-suite
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacViewingState.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacPhotoViewport.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/HistogramPresentation.swift" \
    "$ROOT/RawLabMac/tests/MacInspectionSuiteTests.swift" \
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
