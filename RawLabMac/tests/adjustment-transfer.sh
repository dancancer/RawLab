#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-adjustment-transfer
rawlab_mac_adjustment_native_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "${RAWLAB_TRANSFER_TEST_SOURCE:-$ROOT/RawLabMac/tests/AdjustmentTransferTests.swift}" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
