#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
source "$ROOT/RawLabMac/tests/core-link.sh"
DEPENDENCY_PREFIX="$RAWLAB_DEPENDENCY_PREFIX"
LINK_PACKAGES=(libraw_r rawlab-dng-sdk libtiff-4)
# A focused geometry build may disable these optional processing stages.
for package in opencv4 wavelib lensfun; do
    if pkg-config --exists "$package"; then LINK_PACKAGES+=("$package"); fi
done
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
if [ -n "${RAWLAB_GEOMETRY_RENDER_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_GEOMETRY_RENDER_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-geometry-render
fi
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
rawlab_mac_full_app_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
    "${SOURCES[@]}" \
    "$ROOT/RawLabMac/tests/GeometryRenderTests.swift" \
    "${CORE_LINK[@]}" $(pkg-config --libs "${LINK_PACKAGES[@]}") \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$RAW" "$OUT"
if [ -n "${RAWLAB_GEOMETRY_RENDER_OUTPUT_DIR:-}" ]; then
    echo "Artifacts: $OUT"
fi
