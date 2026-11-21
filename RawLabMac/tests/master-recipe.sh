#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-master-recipe
rawlab_mac_adjustment_native_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "$ROOT/RawLabMac/tests/MasterRecipeTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/master-recipe-tests"
"$OUT/master-recipe-tests"
