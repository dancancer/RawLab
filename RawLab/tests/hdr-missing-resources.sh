#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${3:?Pass a generated HDR JPEG fixture as the third argument}"
SIMCTL_CHILD_RAWLAB_TEST_CAMERA_RAW="$ROOT/lutools/tests/fixtures/bayer-demosaic.dng" \
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/HDRMissingResourceTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
