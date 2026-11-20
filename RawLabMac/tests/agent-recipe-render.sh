#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
INPUT="${1:?Pass a real RAW fixture}"
CLI="${2:?Pass the sony2fuji CLI executable}"
LENS_DATABASE="${3:-$ROOT/lutools/tests/fixtures/lenses.xml}"
LENS_RAW="${4:-$ROOT/lutools/tests/fixtures/linear-lens.dng}"
MODE="${5:-}"

rawlab_mac_make_temp_dir OUT rawlab-agent-recipe
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/agent-recipe-render" -- \
    "$ROOT/RawLabMac/tests/AgentRecipe.swift" \
    "${RAWLAB_AGENT_TEST_SOURCE:-$ROOT/RawLabMac/tests/AgentRecipeRenderTests.swift}" \
    -framework MetalKit

ARGS=("$INPUT" "$CLI")
if [ -n "$MODE" ]; then ARGS+=("$MODE"); fi
RAWLAB_TEST_ROOT="$ROOT" RAWLAB_LENS_DATABASE="$LENS_DATABASE" RAWLAB_LENS_RAW="$LENS_RAW" \
    "$OUT/agent-recipe-render" "${ARGS[@]}"
