#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${RAWLAB_TEST_RAW:?Pass an external X3F fixture}"
RAWLAB_PROCESSOR_TEST_SOURCE="$ROOT/RawLab/tests/X3fWorkflowTests.swift" \
    bash "$ROOT/RawLab/tests/processor-export.sh" "$@"
