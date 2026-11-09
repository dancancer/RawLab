#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-typecheck.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# 直接检查共用清单，避免只有完整应用的通配符编译能补齐遗漏的依赖。
swiftc -typecheck -swift-version 5 -sdk "$SDK" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ColorGradingNative.swift" \
    "$ROOT/Shared/ToneCurveNative.swift" "${HDR_SWIFT_SOURCES[@]}"
echo "PASS: shared HDR native sources typecheck"
