#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-folder-drop.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/RawLabMac/Sources/FileLibrary.swift" \
    "$ROOT/RawLabMac/tests/FolderDropTests.swift" \
    -framework SwiftUI -framework AppKit -framework ImageIO -o "$OUT/folder-drop"
"$OUT/folder-drop"
