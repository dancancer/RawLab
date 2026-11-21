#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAWLAB_BATCH_TEST_SOURCE="$ROOT/RawLabMac/tests/BatchCancellationTests.swift" \
    bash "$ROOT/RawLabMac/tests/batch-render.sh" "$ROOT/lutools/tests/fixtures/bayer-demosaic.dng"
