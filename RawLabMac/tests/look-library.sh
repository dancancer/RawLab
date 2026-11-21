#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_native_env
rawlab_mac_make_temp_dir OUT rawlab-look-library
SOURCES=("$ROOT/RawLabMac/tests/LookLibraryTests.swift" "$ROOT/RawLabMac/tests/DCPTestFixtures.swift" "$ROOT/Shared/DCPCompiler.swift")
if [ -f "$ROOT/Shared/LookLibrary.swift" ]; then
    SOURCES+=("$ROOT/Shared/LookLibrary.swift")
fi
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "${CORE_LINK[@]}" \
    -L "$(pkg-config --variable=libdir libraw_r)" -lraw_r $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework Metal -o "$OUT/look-library"
"$OUT/look-library"

# 同时验证 UI 使用的编辑器状态和持久化删除链路。
bash "$ROOT/RawLabMac/tests/look-import-model.sh"
