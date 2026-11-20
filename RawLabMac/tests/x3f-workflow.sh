#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
: "${RAWLAB_TEST_RAW:?Pass an external supported X3F fixture}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
rawlab_mac_make_temp_dir OUT rawlab-mac-x3f
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/test" -- \
    -parse-as-library -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/tests/AgentRecipe.swift" \
    "$ROOT/RawLabMac/tests/X3FWorkflowTests.swift"
"$OUT/test" "$RAWLAB_TEST_RAW" "$BUILD/sony2fuji"
