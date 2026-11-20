#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
rawlab_mac_make_temp_dir TEMP rawlab-hdr-batch
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
RAWLAB_BATCH_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRBatchTests.swift" \
    RAWLAB_TEST_CAMERA_RAW="$ROOT/lutools/tests/fixtures/bayer-demosaic.dng" \
    bash "$ROOT/RawLabMac/tests/batch-render.sh" "$TEMP/source.jpg"
