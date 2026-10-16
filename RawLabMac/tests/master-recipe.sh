#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-master-recipe.XXXXXX)"
SDK="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)}"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
    "$ROOT/RawLabMac/tests/MasterRecipeTests.swift" \
    -framework Foundation -framework ImageIO -o "$OUT/master-recipe-tests"
"$OUT/master-recipe-tests"
rm -rf "$OUT"
