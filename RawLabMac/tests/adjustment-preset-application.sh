#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-preset-application.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
           "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" \
    "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferWB.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift" \
    "$ROOT/RawLabMac/tests/AdjustmentPresetApplicationTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
"$OUT/test"
