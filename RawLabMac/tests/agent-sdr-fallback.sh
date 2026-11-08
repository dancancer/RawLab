#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
INPUT="${1:?Pass a verified ISO/Adobe gain-map photo (macOS 14 exercises the SDR fallback rejection)}"
RAWLAB_AGENT_TEST_SOURCE="$ROOT/RawLabMac/tests/AgentRecipeSDRFallbackTests.swift" \
    bash "$ROOT/RawLabMac/tests/agent-recipe-render.sh" "$INPUT" "$BUILD/sony2fuji"
