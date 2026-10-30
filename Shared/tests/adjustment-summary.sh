#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-adjustment-summary.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/Localization.swift" "$ROOT/Shared/ColorGradingSettings.swift" \
    "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/AdjustmentTransfer.swift" \
    "$ROOT/Shared/AdjustmentTransferSummary.swift" "$ROOT/Shared/tests/AdjustmentTransferSummaryTests.swift" \
    -o "$BUILD/adjustment-summary"
"$BUILD/adjustment-summary" "$ROOT/Shared/fixtures/adjustment-summary-v1.json" "$ROOT/RawLab/RawLab/Resources"
