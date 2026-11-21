#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-effects-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/PhotoEffectsRenderTests.swift"
"$OUT/test" "${1:?Pass a real RAW fixture}" "${2:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}" "${3:-none}"
