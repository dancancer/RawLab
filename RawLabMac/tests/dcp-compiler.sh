#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-dcp-compiler
for source in core/dcp_compiler ffi/dcp_compiler_c; do
    rawlab_mac_clangxx -std=c++17 -O2 \
        -I "$ROOT/lutools/include" -I "$ROOT/lutools/third_party" \
        -c "$ROOT/lutools/src/$source.cpp" -o "$OUT/$(basename "$source").o"
done
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
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
