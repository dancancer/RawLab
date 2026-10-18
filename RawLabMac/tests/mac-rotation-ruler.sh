#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-mac-rotation-ruler.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/Shared/Localization.swift" "$ROOT/RawLabMac/Sources/Lens/MacRotationRuler.swift" \
    "$ROOT/RawLabMac/tests/MacRotationRulerTests.swift" \
    -framework AppKit -framework SwiftUI -o "$OUT/tests"
"$OUT/tests"
