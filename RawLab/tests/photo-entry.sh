#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-photo-entry.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/profile"
RAWLAB_TEST_PHOTO_LIBRARY=1 SIMCTL_CHILD_CFFIXED_USER_HOME="$OUT/profile" RAWLAB_IMPORT_STATE_OUT="$OUT" \
RAWLAB_IMPORT_STATE_TEST_SOURCE="$ROOT/RawLab/tests/PhotoEntryTests.swift" \
    bash "$ROOT/RawLab/tests/import-state.sh" "$@"
