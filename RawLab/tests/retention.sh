#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-retention.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Storage/RetentionPolicy.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/ExportEvidenceStore.swift" \
    "$ROOT/RawLab/tests/RetentionTests.swift" -o "$OUT/tests"
"$OUT/tests"
