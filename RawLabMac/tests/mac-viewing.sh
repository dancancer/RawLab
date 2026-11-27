#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-viewing
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Presentation/MacPhotoViewport.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacViewingState.swift" \
    "$ROOT/RawLabMac/tests/MacViewingTests.swift" -o "$OUT/test"
"$OUT/test"
