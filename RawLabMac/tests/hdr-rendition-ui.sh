#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-rendition-ui.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/HDRAdjustmentTransfer.swift" "$ROOT/Shared/HDRDisplay.swift" \
    "$ROOT/Shared/Native/HDRCanvas.swift" "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLabMac/tests/HDRRenditionUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
