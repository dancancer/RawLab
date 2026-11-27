#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-adjustment-transfer
rawlabnative_flags link "$OUT/swiftpm" macos 0 types_only
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${RAWLAB_TRANSFER_TEST_SOURCE:-$ROOT/RawLabMac/tests/AdjustmentTransferTests.swift}" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
