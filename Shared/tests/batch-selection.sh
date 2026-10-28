#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-batch-selection.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc "$ROOT/Shared/BatchSelectionSession.swift" "$ROOT/Shared/tests/BatchSelectionSessionTests.swift" -o "$OUT/test"
"$OUT/test"
