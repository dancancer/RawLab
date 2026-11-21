#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-hdr-source-probe
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Native/HDRSource.swift" \
    "$ROOT/Shared/tests/HDRSourceProbeTests.swift" "$ROOT/Shared/tests/HDRSourceProbeHarness.swift" \
    -o "$OUT/test"
"$OUT/test"
