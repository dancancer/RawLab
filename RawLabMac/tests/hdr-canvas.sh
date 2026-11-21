#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-hdr-canvas
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/Native/HDRCanvas.swift" \
    "$ROOT/RawLabMac/tests/HDRCanvasTests.swift" \
    -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit -framework Combine \
    -o "$OUT/test"
"$OUT/test"
