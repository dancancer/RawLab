#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-edit-model
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/tests/EditModelTests.swift"
"$OUT/test" "$@"

VIEWING_RAW="${1:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}"
if [ -f "$VIEWING_RAW" ]; then
    bash "$ROOT/RawLabMac/tests/mac-viewing-model.sh" "$VIEWING_RAW"
fi
