#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-rotation-ruler
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/Sources/Lens/MacRotationRuler.swift" \
    "$ROOT/RawLabMac/tests/MacRotationRulerTests.swift" \
    -framework AppKit -framework SwiftUI -o "$OUT/tests"
"$OUT/tests"
