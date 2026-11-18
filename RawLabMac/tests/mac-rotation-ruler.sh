#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-mac-rotation-ruler.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$OUT/ModuleCache" \
     "$ROOT/RawLabMac/Sources/Lens/MacRotationRuler.swift" \
    "$ROOT/RawLabMac/tests/MacRotationRulerTests.swift" \
    -framework AppKit -framework SwiftUI -o "$OUT/tests"
"$OUT/tests"
