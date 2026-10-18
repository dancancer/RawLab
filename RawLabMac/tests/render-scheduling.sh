#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-render-scheduling.XXXXXX)"
swiftc -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/RawLabMac/Sources/Rendering/RenderScheduling.swift" \
    "$ROOT/RawLabMac/tests/RenderSchedulingTests.swift" \
    -o "$OUT/render-scheduling"
"$OUT/render-scheduling"
