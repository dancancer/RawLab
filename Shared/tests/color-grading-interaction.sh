#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-grading-interaction.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/ColorGradingWheelControl.swift" "$ROOT/Shared/tests/ColorGradingInteractionTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
