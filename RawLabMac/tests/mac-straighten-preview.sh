#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="${RAWLAB_STRAIGHTEN_PREVIEW_OUTPUT_DIR:-$ROOT/build/mac-straighten-evidence}"
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}}"
test -f "$RAW" || { echo "Missing RAW fixture: $RAW" >&2; exit 1; }
test -f "$BUILD/libsony2fuji_core.a" || { echo 'Build the Mac core first: bash RawLabMac/build.sh' >&2; exit 1; }
mkdir -p "$OUT"
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -O -whole-module-optimization \
    -num-threads "${JOBS:-$(sysctl -n hw.ncpu)}" \
    -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/tests/MacStraightenPreviewTests.swift" \
    "$ROOT/RawLabMac/tests/StraightenPreviewFixtures.swift" \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)"
"$OUT/test" "$RAW" "$OUT"
echo "Artifacts: $OUT"
