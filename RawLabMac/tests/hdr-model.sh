#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir BUILD rawlab-mac-hdr-model
rawlab_mac_adjustment_native_sources SOURCES
rawlabkit_flags link "$BUILD/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "$ROOT/RawLabMac/tests/HDRModelTests.swift" \
    -framework Foundation -framework ImageIO -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-transfer.sh"
