#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-request.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
# 错误映射不依赖原生解码，单独编译该类型即可验证实际返回文案。
sed '/^struct HDRSourceInfo/,$d' "$ROOT/Shared/Native/HDRSource.swift" > "$BUILD/HDRNativeError.swift"
SOURCES=( "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ColorGradingNative.swift"
     "$ROOT/Shared/ToneCurveNative.swift"
     "$ROOT/Shared/Native/HDRRequest.swift" "$BUILD/HDRNativeError.swift")
rawlabkit_flags link "$BUILD/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT/Shared/tests/HDRNativeRequestTests.swift" -o "$BUILD/test"
"$BUILD/test"
