#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-dcp-compiler.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
for source in core/dcp_compiler ffi/dcp_compiler_c; do
    xcrun clang++ -std=c++17 -O2 -isysroot "$SDK" \
        -target "$ARCH-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
        -I "$ROOT/lutools/include" -I "$ROOT/lutools/third_party" \
        -c "$ROOT/lutools/src/$source.cpp" -o "$OUT/$(basename "$source").o"
done
swiftc -swift-version 5 -O -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$ARCH-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/Shared/DCPCompiler.swift" \
    "$ROOT/RawLabMac/tests/DCPTestFixtures.swift" \
    "$ROOT/RawLabMac/tests/DCPCompilerTests.swift" "$OUT"/*.o -lc++ -o "$OUT/dcp-compiler"
"$OUT/dcp-compiler"
if [ -n "${RAWLAB_DCP_FIXTURE_DIR:-}" ]; then
    "$OUT/dcp-compiler" --fixtures "$RAWLAB_DCP_FIXTURE_DIR"
fi
if [ -n "${RAWLAB_LUTPREP_PYTHON:-}" ]; then
    PYTHONDONTWRITEBYTECODE=1 "$RAWLAB_LUTPREP_PYTHON" "$ROOT/lutools/tests/test_dcp_compiler.py" "$OUT/dcp-compiler"
fi
