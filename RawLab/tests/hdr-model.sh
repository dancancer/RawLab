#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-hdr-model.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
rawlabkit_flags link "$BUILD/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
 "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/tests/HDRModelTests.swift" -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLab/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLab/tests/adjustment-transfer.sh"
