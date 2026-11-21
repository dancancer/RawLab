#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
if [ -n "${RAWLAB_PERSPECTIVE_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_PERSPECTIVE_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-mac-perspective
fi
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an existing RAW path' >&2; exit 1; }
test -f "$BUILD/libsony2fuji_core.a" || { echo 'Build the Mac core first: bash RawLabMac/build.sh' >&2; exit 1; }
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -O -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/tests/MacPerspectiveIntegrationTests.swift" \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)"
"$OUT/test" "$RAW" "$OUT"
if [ -n "${RAWLAB_PERSPECTIVE_OUTPUT_DIR:-}" ]; then
    echo "Artifacts: $OUT"
fi
