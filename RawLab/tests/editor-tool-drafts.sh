#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-tool-drafts.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" -module-cache-path "$OUT/modules" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/ProcessingMigration.swift" "$ROOT/Shared/ToneControlsSettings.swift" \
    "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/HDRAdjustmentTransfer.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" "$ROOT/RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift" "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferWB.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/EditorToolDraft.swift" "$ROOT/RawLab/tests/EditorToolDraftTests.swift" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
