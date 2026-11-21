#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-hsl-target-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/HSLTargetRenderTests.swift"
"$OUT/test" "$@"
