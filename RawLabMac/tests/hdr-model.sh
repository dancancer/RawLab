#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-mac-hdr-model.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
rawlabkit_flags link "$BUILD/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" \
    "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/tests/HDRModelTests.swift" \
    -framework Foundation -framework ImageIO -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-transfer.sh"
