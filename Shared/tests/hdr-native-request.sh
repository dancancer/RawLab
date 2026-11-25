#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir BUILD rawlab-hdr-request
# 错误映射不依赖原生解码，单独编译该类型即可验证实际返回文案。
sed '/^struct HDRSourceInfo/,$d' "$ROOT/Shared/Native/HDRSource.swift" > "$BUILD/HDRNativeError.swift"
SOURCES=( "$BUILD/HDRNativeError.swift" )
rawlabnative_flags link "$BUILD/swiftpm" macos 0 types_only
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT/Shared/tests/HDRNativeRequestTests.swift" -o "$BUILD/test"
"$BUILD/test"
