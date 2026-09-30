#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-file-browser.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/RawLabMac/Sources/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/FileBrowser.swift" \
    "$ROOT/RawLabMac/tests/FileBrowserTests.swift" \
    -framework SwiftUI -framework AppKit -framework ImageIO -o "$OUT/file-browser"
"$OUT/file-browser"
