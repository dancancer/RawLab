#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
INPUT="${1:?Pass a real RAW fixture}"
CLI="${2:?Pass the sony2fuji CLI executable}"

rawlab_mac_make_temp_dir OUT rawlab-raster-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/raster-render" -- \
    -O "$ROOT/RawLabMac/tests/AgentRecipe.swift" \
    "$ROOT/RawLabMac/tests/Raster/"*.swift \
    -framework MetalKit

RAWLAB_TEST_ROOT="$ROOT" "$OUT/raster-render" "$INPUT" "$CLI"
