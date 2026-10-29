#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${RAWLAB_TEST_HDR:?Pass a read-only HDR original path}"
export SIMCTL_CHILD_RAWLAB_TEST_HDR="$RAWLAB_TEST_HDR"
RAWLAB_PROCESSOR_TEST_SOURCE="$ROOT/RawLab/tests/HDRProcessingTests.swift" \
    bash "$ROOT/RawLab/tests/processor-export.sh" "${1:?Built simulator RawLab.app}" "${2:?Task-owned simulator UUID}"
