#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-tone-curve-render
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    -O "$ROOT/RawLabMac/tests/AgentRecipe.swift" \
    "$ROOT/Shared/ToneCurveSampling.swift" \
    "$ROOT/RawLabMac/tests/ToneCurveRenderTests.swift"
"$OUT/test"
