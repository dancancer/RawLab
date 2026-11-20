#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-hdr-typecheck

# 直接检查共用清单，避免只有完整应用的通配符编译能补齐遗漏的依赖。
rawlabkit_flags typecheck "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -typecheck \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ColorGradingNative.swift" \
    "$ROOT/Shared/ToneCurveNative.swift" "${HDR_SWIFT_SOURCES[@]}"
echo "PASS: shared HDR native sources typecheck"
