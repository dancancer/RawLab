#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-adjustment-scale.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentScale.swift" \
    "$ROOT/RawLab/tests/AdjustmentScaleTests.swift" -o "$OUT/adjustment-scale"
"$OUT/adjustment-scale"
