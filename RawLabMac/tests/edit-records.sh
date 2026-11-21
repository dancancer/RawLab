#!/bin/bash
# P2-01 (S1): 持久化编辑记录 golden fixture (Shared/fixtures/edit-records-v1.json) macOS 模型层测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-edit-records
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/tests/EditRecordFixtureTests.swift" \
    -framework Foundation -framework CryptoKit -framework UniformTypeIdentifiers -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
