#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-history.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
"${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/hdr_image_tests" --fixture "$OUT/source.jpg"
RAWLAB_HISTORY_TEST_SOURCE="$ROOT/RawLabMac/tests/HDRHistoryTests.swift" \
    bash "$ROOT/RawLabMac/tests/adjustment-history-model.sh" "$OUT/source.jpg"
