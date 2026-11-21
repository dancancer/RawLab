#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-look-model
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/look-import-model" -- \
    -O "$ROOT/RawLabMac/tests/DCPTestFixtures.swift" \
    "$ROOT/RawLabMac/Sources/Looks/FilmDock.swift" \
    "$ROOT/RawLabMac/Sources/Library/FilmArtwork.swift" \
    "$ROOT/RawLabMac/tests/LookImportModelTests.swift" \
    -framework MetalKit
"$OUT/look-import-model"
