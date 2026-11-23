#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-inspection-suite
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorCoordinator.swift" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" \
    "$ROOT/RawLab/tests/IOSInspectionSuiteTests.swift" \
    -framework SwiftUI -framework PhotosUI -framework UniformTypeIdentifiers -framework ImageIO \
    -o "$OUT/ios-inspection-suite-tests"
"$OUT/ios-inspection-suite-tests"
