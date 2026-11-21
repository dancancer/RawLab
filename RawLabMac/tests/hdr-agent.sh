#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
rawlab_mac_make_temp_dir TEMP rawlab-hdr-agent
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
RAWLAB_AGENT_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRAgentTests.swift" \
    bash "$ROOT/RawLabMac/tests/agent-recipe-render.sh" "$TEMP/source.jpg" "$BUILD/sony2fuji"
