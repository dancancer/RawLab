#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-histogram.XXXXXX)"
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/RawLabMac/Sources/Presentation/HistogramPresentation.swift" \
    "$ROOT/RawLabMac/tests/HistogramTests.swift" \
    -o "$OUT/histogram"
"$OUT/histogram"
