#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-denoise-model
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/DenoiseModelTests.swift"
"$OUT/test" "${1:?Pass a RAW fixture}"
