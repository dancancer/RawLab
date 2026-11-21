#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-control-groups
rawlab_mac_adjustment_native_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "$ROOT/RawLabMac/Sources/Controls/MacHSLPrecision.swift" "$ROOT/RawLabMac/tests/ControlGroupTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
"$OUT/test"
