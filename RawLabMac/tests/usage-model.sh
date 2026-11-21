#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-usage-model
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/AgentRecipe.swift" \
    "$ROOT/RawLabMac/tests/UsageModelTests.swift"
"$OUT/test" "$@"
