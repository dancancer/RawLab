#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-lut-library
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library \
    -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/Core/Looks/IOSLUTLibrarySelection.swift" \
    "$ROOT/RawLab/tests/LUTLibrarySelectionTests.swift" \
    -framework PhotosUI -framework SwiftUI -o "$OUT/library-selection"
"$OUT/library-selection"
