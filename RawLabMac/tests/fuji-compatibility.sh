#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-fuji
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/fuji-compatibility" -- \
    -parse-as-library -O \
    "$ROOT/RawLabMac/tests/FujiCompatibilityTests.swift"
"$OUT/fuji-compatibility" "$@"
