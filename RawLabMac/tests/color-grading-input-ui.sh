#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/RawLabMac/tests/ax-gate.sh"
rawlab_ax_gate
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-grading-input-ui
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/ColorGradingWheelControl.swift" \
    "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift" \
    "$ROOT/RawLabMac/tests/ColorGradingInputUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
