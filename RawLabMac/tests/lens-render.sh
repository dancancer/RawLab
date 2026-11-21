#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DSC06251.ARW}}"
if [ ! -f "$RAW" ]; then echo "Real RAW fixture unavailable: $RAW" >&2; exit 1; fi
rawlab_mac_make_temp_dir OUT rawlab-lens-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/lens-render" -- \
    -O "$ROOT/RawLabMac/tests/LensRenderTests.swift"
"$OUT/lens-render" "$RAW" "$ROOT/lutools/third_party/lensfun/version_1"
