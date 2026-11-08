#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/HDRBatchTests.swift" \
    SIMCTL_CHILD_RAWLAB_TEST_CAMERA_RAW="$ROOT/lutools/tests/fixtures/bayer-demosaic.dng" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
