#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
if [ -n "${RAWLAB_VIEWING_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_VIEWING_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-mac-viewing-model
fi
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/tests/MacViewingModelTests.swift" \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)"
"$OUT/test" "${1:?Pass RAW fixture}" "$OUT"
