#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/HDRHistoryTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "${1:?Built simulator RawLab.app}" "${2:?Task-owned simulator UUID}" \
        "${3:-$ROOT/lutools/tests/fixtures/hdr/apple-legacy-macos26.jpg}"
