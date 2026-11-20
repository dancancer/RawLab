#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
INPUT="${1:?Pass a real RAW fixture}"
rawlab_mac_make_temp_dir OUT rawlab-chroma-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/ChromaRenderTests.swift"
"$OUT/test" "$INPUT" "${@:2}"
