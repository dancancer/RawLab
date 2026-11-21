#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-hdr-history
"${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/hdr_image_tests" --fixture "$OUT/source.jpg"
RAWLAB_HISTORY_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRHistoryTests.swift" \
    RAWLAB_TEST_CAMERA_RAW="$ROOT/lutools/tests/fixtures/bayer-demosaic.dng" \
    bash "$ROOT/RawLabMac/tests/adjustment-history-model.sh" "$OUT/source.jpg"
