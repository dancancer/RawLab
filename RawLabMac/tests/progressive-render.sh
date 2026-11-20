#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-progressive-render
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
LUT="${2:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}"

rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/progressive-render" -- \
    -parse-as-library -O "$ROOT/RawLabMac/tests/ProgressiveRenderTests.swift"

if [[ "${RUN_PROGRESSIVE_RENDER:-0}" != "1" ]]; then
    echo "PASS: progressive render integration binary compiled ($OUT/progressive-render)"
    echo "Set RUN_PROGRESSIVE_RENDER=1 to execute RAW renders."
    exit 0
fi

"$OUT/progressive-render" "$RAW" "$LUT"
