#!/bin/bash
# P2-01 (S1): 持久化编辑记录 golden fixture (Shared/fixtures/edit-records-v1.json) iOS 模型层测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-edit-records.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/modules}" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/ProcessingMigration.swift" \
    "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift" \
    "$ROOT/RawLab/tests/EditRecordFixtureTests.swift" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
