#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-mac-hdr-model.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/tests/HDRModelTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
bash "$ROOT/Shared/tests/hdr-transfer.sh"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-transfer.sh"
