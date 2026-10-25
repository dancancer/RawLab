#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-mac-crop-presentation.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift" "$ROOT/RawLabMac/Sources/Geometry/MacCropOverlay.swift" \
    "$ROOT/RawLabMac/tests/MacCropPresentationTests.swift" -framework AppKit -framework SwiftUI -o "$OUT/tests"
"$OUT/tests" "${1:-$ROOT/build/mac-crop-evidence}"
