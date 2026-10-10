#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ai-data.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
SOURCES=("$ROOT/RawLabMac/tests/AIDataTests.swift")
for name in AIColorRecipe AIService AIImage AISettings; do
    if [ -f "$ROOT/RawLabMac/Sources/$name.swift" ]; then SOURCES+=("$ROOT/RawLabMac/Sources/$name.swift"); fi
done
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx15.0" \
  "${SOURCES[@]}" -framework AppKit -framework ImageIO -framework Security -o "$OUT/test"
"$OUT/test"
