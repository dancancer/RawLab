#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-edited-photo-cache.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -whole-module-optimization -swift-version 5 \
    "$ROOT/Shared/EditedPhotoPreviewCache.swift" \
    "$ROOT/Shared/tests/EditedPhotoPreviewCacheTests.swift" -o "$OUT/tests"
"$OUT/tests"
