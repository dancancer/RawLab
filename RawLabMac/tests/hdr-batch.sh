#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-batch.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
RAWLAB_BATCH_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRBatchTests.swift" \
    bash "$ROOT/RawLabMac/tests/batch-render.sh" "$TEMP/source.jpg"
