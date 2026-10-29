#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAWLAB_BATCH_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRSDRPreviewTests.swift" \
    bash "$ROOT/RawLabMac/tests/batch-render.sh" "${RAWLAB_TEST_HDR:?Pass a read-only HDR original}"
