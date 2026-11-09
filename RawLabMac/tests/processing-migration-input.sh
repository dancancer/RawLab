#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAWLAB_HISTORY_TEST_SOURCE="$ROOT/RawLabMac/tests/ProcessingMigrationInputTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-history-model.sh" "$@"
