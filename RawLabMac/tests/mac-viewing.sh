#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-mac-viewing.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" "$ROOT/RawLabMac/Sources/Presentation/MacViewingState.swift" "$ROOT/RawLabMac/tests/MacViewingTests.swift" -o "$OUT/test"
"$OUT/test"
