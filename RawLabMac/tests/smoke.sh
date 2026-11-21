#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
APP="${RAWLAB_APP_PATH:-$ROOT/build/RawLab Mac.app}/Contents/MacOS/RawLabMac"
test -x "$APP" || { echo 'FAIL: RawLab Mac executable missing'; exit 1; }
if [ -n "${RAWLAB_SMOKE_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_SMOKE_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-mac-smoke
fi
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
"$APP" --smoke "$RAW" "$OUT/raw"
if [ -f "$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG" ]; then
    "$APP" --smoke "$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG" "$OUT/dji"
fi
if "$APP" --smoke "$OUT/missing.raw" "$OUT/missing"; then
    echo 'FAIL: missing RAW accepted'; exit 1
fi
if [ -n "${RAWLAB_SMOKE_OUTPUT_DIR:-}" ]; then
    echo "PASS: Mac smoke outputs in $OUT"
else
    echo "PASS: Mac smoke checks passed"
fi
