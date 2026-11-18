#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-ios-adjustment-transfer.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$SDK" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/modules}" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/FileDigestCache.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferWB.swift" \
    "${RAWLAB_TRANSFER_TEST_SOURCE:-$ROOT/RawLab/tests/AdjustmentTransferTests.swift}" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
