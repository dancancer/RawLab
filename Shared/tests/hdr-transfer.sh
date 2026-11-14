#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-transfer.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -whole-module-optimization -swift-version 5 "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/HDRAdjustmentTransfer.swift" "$ROOT/Shared/AdjustmentPresetStore.swift" \
    "$ROOT/Shared/PresetJSONScanner.swift" "$ROOT/Shared/tests/HDRTransferTests.swift" -o "$BUILD/hdr-transfer"
"$BUILD/hdr-transfer"
