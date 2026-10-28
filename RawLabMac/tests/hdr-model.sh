#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-mac-hdr-model.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" \
    "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" \
    "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/tests/HDRModelTests.swift" \
    -framework Foundation -framework ImageIO -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
bash "$ROOT/Shared/tests/hdr-transfer.sh"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-transfer.sh"
