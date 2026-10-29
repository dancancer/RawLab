#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-agent.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
RAWLAB_AGENT_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRAgentTests.swift" \
    bash "$ROOT/RawLabMac/tests/agent-recipe-render.sh" "$TEMP/source.jpg" "$BUILD/sony2fuji"
