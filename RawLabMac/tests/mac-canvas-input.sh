#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-mac-canvas-input.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 "$ROOT/RawLabMac/Sources/Presentation/MacCanvasInput.swift" "$ROOT/RawLabMac/tests/MacCanvasInputTests.swift" -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
