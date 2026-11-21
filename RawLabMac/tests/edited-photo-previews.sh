#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-edited-preview
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowserState.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowser.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacEditedPhotoPreviews.swift" \
    "$ROOT/RawLabMac/tests/EditedPhotoPreviewTests.swift" \
    -framework MetalKit
"$OUT/test"
