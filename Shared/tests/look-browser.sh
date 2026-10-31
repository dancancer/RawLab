#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-look-browser.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
swiftc "$ROOT/Shared/BundledLook.swift" "$ROOT/Shared/LookBrowser.swift" \
    "$ROOT/Shared/tests/LookBrowserTests.swift" -o "$OUT/look-browser"
"$OUT/look-browser"
