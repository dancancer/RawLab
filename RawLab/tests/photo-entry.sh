#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_make_temp_dir OUT rawlab-ios-photo-entry
mkdir -p "$OUT/profile"
RAWLAB_TEST_PHOTO_LIBRARY=1 SIMCTL_CHILD_CFFIXED_USER_HOME="$OUT/profile" RAWLAB_IMPORT_STATE_OUT="$OUT" \
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/PhotoEntryTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
