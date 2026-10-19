#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-dcp-compiler.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -O -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLabMac/Sources/Library/DCPCompiler.swift" \
    "$ROOT/RawLabMac/tests/DCPTestFixtures.swift" \
    "$ROOT/RawLabMac/tests/DCPCompilerTests.swift" -o "$OUT/dcp-compiler"
"$OUT/dcp-compiler"
if [ -n "${RAWLAB_DCP_FIXTURE_DIR:-}" ]; then
    "$OUT/dcp-compiler" --fixtures "$RAWLAB_DCP_FIXTURE_DIR"
fi
if [ -n "${RAWLAB_LUTPREP_PYTHON:-}" ]; then
    PYTHONDONTWRITEBYTECODE=1 "$RAWLAB_LUTPREP_PYTHON" "$ROOT/RawLabMac/tests/test_dcp_compiler.py" "$OUT/dcp-compiler"
fi
