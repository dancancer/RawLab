#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-hdr-model.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" "$ROOT/Shared/ToneControlsSettings.swift" \
    "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/tests/HDRModelTests.swift" -o "$BUILD/hdr-model"
"$BUILD/hdr-model"
bash "$ROOT/Shared/tests/hdr-transfer.sh"
RAWLAB_TRANSFER_TEST_SOURCE="$ROOT/RawLab/tests/HDRTransferAdapterTests.swift" \
    bash "$ROOT/RawLab/tests/adjustment-transfer.sh"
