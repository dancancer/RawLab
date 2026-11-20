#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-batch-ui
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/batch-ui" -- \
    -O "$ROOT/RawLabMac/tests/DCPTestFixtures.swift" "$ROOT/RawLabMac/tests/BatchImportPresentationTests.swift"
if [ "${2:-}" = "--compile-only" ]; then
    echo "PASS: batch import presentation sources link; desktop sheet interaction NOT REACHED"
else
    "$OUT/batch-ui" "$1"
fi
