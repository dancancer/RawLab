#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
if [ -n "${RAWLAB_ADJUSTMENTS_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_ADJUSTMENTS_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-adjustments
fi
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/adjustments" -- \
    -O "$ROOT/RawLabMac/tests/AdjustmentTests.swift"
SAMPLES=()
if [ -n "${RAWLAB_TEST_RAW:-}" ]; then SAMPLES+=("$RAWLAB_TEST_RAW"); fi
for raw in "$ROOT"/lutools/examples/*; do
    case "$raw" in
        *.[Aa][Rr][Ww]|*.[Dd][Nn][Gg]|*.[Nn][Ee][Ff]|*.[Cc][Rr]2|*.[Cc][Rr]3|*.[Rr][Aa][Ff]|*.[Rr][Ww]2|*.[Oo][Rr][Ff]) SAMPLES+=("$raw") ;;
    esac
done
test "${#SAMPLES[@]}" -gt 0 || { echo 'Set RAWLAB_TEST_RAW to an external RAW path'; exit 1; }
for raw in "${SAMPLES[@]}"; do
    "$OUT/adjustments" "$ROOT" "$OUT/$(basename "$raw")" "$raw"
done
if [ -n "${RAWLAB_ADJUSTMENTS_OUTPUT_DIR:-}" ]; then
    echo "PASS: ${#SAMPLES[@]} RAW fixtures; artifacts in $OUT"
else
    echo "PASS: ${#SAMPLES[@]} RAW fixtures"
fi
