#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${RAWLAB_TEST_HDR:?Pass a read-only HDR original}"
SIMCTL_CHILD_RAWLAB_TEST_HDR="$RAWLAB_TEST_HDR" \
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/HDRSDRPreviewTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
