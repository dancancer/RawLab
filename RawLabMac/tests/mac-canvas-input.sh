#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-mac-canvas-input.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 "$ROOT/RawLabMac/Sources/Presentation/MacCanvasInput.swift" "$ROOT/RawLabMac/tests/MacCanvasInputTests.swift" -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
