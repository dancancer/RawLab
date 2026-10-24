#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-grading-interaction.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/ColorGradingSettings.swift" \
    "$ROOT/Shared/ColorGradingWheelControl.swift" "$ROOT/Shared/tests/ColorGradingInteractionTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
