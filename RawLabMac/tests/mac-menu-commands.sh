#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-mac-menu-commands
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/tests/MacMenuAndSummaryTests.swift"
"$OUT/test"
