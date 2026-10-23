#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-adjustment-session.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" \
    "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferWB.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift" \
    "$ROOT/RawLabMac/tests/AdjustmentTransferSessionTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
