#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-mac-canvas-input
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    "$ROOT/RawLabMac/Sources/Presentation/MacCanvasInput.swift" \
    "$ROOT/RawLabMac/tests/MacCanvasInputTests.swift" -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
