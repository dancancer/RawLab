#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-parameter-value
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/ModuleCache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/Sources/Inputs/ParameterPrecision.swift" \
    "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift" \
    "$ROOT/RawLabMac/Sources/Editor/View/AdjustmentRow.swift" \
    "$ROOT/RawLabMac/tests/ParameterValueTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/parameter-value"
cd "$ROOT"
"$OUT/parameter-value"
