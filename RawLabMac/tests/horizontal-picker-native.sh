#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-horizontal-picker-native
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    "$ROOT/RawLabMac/Sources/Inputs/HorizontalPicker.swift" "$ROOT/RawLabMac/tests/HorizontalPickerNativeTests.swift" \
    -framework AppKit -framework SwiftUI -framework Foundation -o "$OUT/test"
"$OUT/test" "$ROOT"
