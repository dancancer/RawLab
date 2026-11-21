#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
INPUT="${1:?Pass a real RAW fixture}"
OUTPUT="${2:?Pass an ignored validation output directory}"
LUT="${3:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}"
rawlab_mac_make_temp_dir BIN rawlab-rendered-dng
rawlab_mac_compile_native render-engine "$BIN/swiftpm" "$BIN/test" -- \
    "$ROOT/RawLabMac/tests/RenderedDNGExportTests.swift"
"$BIN/test" "$INPUT" "$OUTPUT" "$LUT"
