#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/RawLabMac/tests/ax-gate.sh"
rawlab_ax_gate
OUT="$(mktemp -d /tmp/rawlab-grading-input-ui.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/ColorGradingWheelControl.swift" \
    "$ROOT/RawLabMac/Sources/Inputs/ParameterPrecision.swift" \
    "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift" \
    "$ROOT/RawLabMac/tests/ColorGradingInputUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
