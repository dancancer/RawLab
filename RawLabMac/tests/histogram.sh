#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-histogram
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    "$ROOT/RawLabMac/Sources/Presentation/HistogramPresentation.swift" \
    "$ROOT/RawLabMac/tests/HistogramTests.swift" \
    -o "$OUT/histogram"
"$OUT/histogram"
