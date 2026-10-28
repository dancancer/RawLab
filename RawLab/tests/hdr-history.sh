#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/HDRHistoryTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
