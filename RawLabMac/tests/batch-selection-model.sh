#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-batch-selection
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/Shared/tests/HDRSourceProbeTests.swift" \
    "$ROOT/RawLabMac/tests/BatchSelectionModelTests.swift" \
    "$ROOT/RawLabMac/tests/BatchFlowModelTests.swift"
cd "$ROOT"
TMPDIR="$OUT" "$OUT/test" "$@"
