#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-workspace-browser.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowserState.swift" \
    "$ROOT/RawLabMac/tests/WorkspaceBrowserTests.swift" -o "$OUT/test"
"$OUT/test"
