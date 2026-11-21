#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
rawlab_mac_make_temp_dir OUT rawlab-geometry-viewport
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -O -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/tests/GeometryViewportTests.swift"
"$OUT/test" "$RAW" "${@:2}"
