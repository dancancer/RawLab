#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
INPUT="${1:?Pass a real RAW fixture}"
rawlab_mac_make_temp_dir OUT rawlab-batch-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" \
    "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "${RAWLAB_BATCH_TEST_SOURCE:-$ROOT/RawLabMac/tests/BatchRenderTests.swift}"
"$OUT/test" "$INPUT"
