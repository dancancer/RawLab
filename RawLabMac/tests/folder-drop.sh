#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-folder-drop
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "$ROOT/RawLabMac/tests/FolderDropTests.swift" \
    -framework SwiftUI -framework AppKit -framework ImageIO -o "$OUT/folder-drop"
"$OUT/folder-drop"
