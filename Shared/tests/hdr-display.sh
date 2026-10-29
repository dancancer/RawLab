#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-display.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
SOURCES=("$ROOT/Shared/tests/HDRDisplayTests.swift" "$ROOT/Shared/HDRDisplay.swift")
swiftc -parse-as-library -swift-version 5 -target "${RAWLAB_ARCH:-$(uname -m)}-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "${SOURCES[@]}" -o "$TEMP/test"
"$TEMP/test"
