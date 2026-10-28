#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-batch.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/ExportSize.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/CachedPhotoFile.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Model/BatchExportModels.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Storage/BatchExportStorage.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Execution/BatchExportRunner.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Model/BatchSettingsSummary.swift" \
    "$ROOT/RawLab/tests/ImportState/BatchSourceJournalTests.swift" \
    "$ROOT/Shared/BatchSelectionSession.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Model/IOSBatchSelection.swift" \
    "$ROOT/RawLab/tests/BatchSelectionTests.swift" \
    "$ROOT/RawLab/tests/BatchExportTests.swift" \
    -o "$OUT/batch-export"
mkdir -p "$OUT/profile"
CFFIXED_USER_HOME="$OUT/profile" RAWLAB_TEST_PROFILE="$OUT/profile" "$OUT/batch-export"
