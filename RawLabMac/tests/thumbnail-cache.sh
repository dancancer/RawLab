#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-thumbnail-cache
rawlab_mac_adjustment_native_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowserState.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacEditedPhotoPreviews.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowser.swift" \
    "$ROOT/RawLabMac/tests/ThumbnailCacheTests.swift" \
    -framework SwiftUI -framework AppKit -framework ImageIO -o "$OUT/thumbnail-cache"
"$OUT/thumbnail-cache"
