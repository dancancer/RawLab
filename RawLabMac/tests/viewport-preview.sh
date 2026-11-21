#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
if [ -n "${RAWLAB_VIEWPORT_PREVIEW_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_VIEWPORT_PREVIEW_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-viewport-preview
fi
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -O "$ROOT/RawLabMac/tests/ViewportPreviewTests.swift"
"$OUT/test" "$RAW" "$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube" "$OUT" "${@:2}"
if [ -n "${RAWLAB_VIEWPORT_PREVIEW_OUTPUT_DIR:-}" ]; then
    echo "Artifacts: $OUT"
fi
