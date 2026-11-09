#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-request.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
# 错误映射不依赖原生解码，单独编译该类型即可验证实际返回文案。
sed '/^struct HDRSourceInfo/,$d' "$ROOT/Shared/Native/HDRSource.swift" > "$BUILD/HDRNativeError.swift"
SOURCES=("$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ColorGradingNative.swift"
    "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/ToneCurveNative.swift"
    "$ROOT/Shared/HDRRecipe.swift" "$ROOT/Shared/Native/HDRRequest.swift" "$BUILD/HDRNativeError.swift")
swiftc -whole-module-optimization -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT/Shared/tests/HDRNativeRequestTests.swift" -o "$BUILD/test"
"$BUILD/test"
