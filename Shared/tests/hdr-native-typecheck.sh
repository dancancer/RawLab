#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-hdr-typecheck

# 直接检查共用清单，避免只有完整应用的通配符编译能补齐遗漏的依赖。
rawlabnative_flags typecheck "$OUT/swiftpm" macos 0 types_only
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -typecheck \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${HDR_SWIFT_SOURCES[@]}"
echo "PASS: shared HDR native sources typecheck"
