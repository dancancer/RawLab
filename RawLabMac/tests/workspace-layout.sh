#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-workspace-layout.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
swiftc "$ROOT/RawLabMac/Sources/Editor/View/AdjustmentPanelLayout.swift" \
    "$ROOT/RawLabMac/tests/WorkspaceLayoutTests.swift" -o "$OUT/workspace-layout"
"$OUT/workspace-layout"
