#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-master-recipe.XXXXXX)"
SDK="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" \
           "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLabMac/tests/MasterRecipeTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/master-recipe-tests"
"$OUT/master-recipe-tests"
rm -rf "$OUT"
