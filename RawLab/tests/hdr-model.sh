#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir BUILD rawlab-ios-hdr-model
rawlabkit_flags link "$BUILD/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/tests/HDRModelTests.swift" -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLab/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLab/tests/adjustment-transfer.sh"
