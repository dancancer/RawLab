#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-parameter-value.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/ModuleCache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/RawLabMac/Sources/MasterRecipe.swift" "$ROOT/RawLabMac/Sources/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/ParameterPrecision.swift" "$ROOT/RawLabMac/Sources/ParameterValueField.swift" \
    "$ROOT/RawLabMac/tests/ParameterValueTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/parameter-value"
cd "$ROOT"
"$OUT/parameter-value"
