#!/bin/bash
# 本地/发布前手工 UI 检查（依赖 macOS 辅助功能 AXUIElement 授权，CI 不执行；
# CI 模型门禁改由不依赖辅助功能权限的 RawLabMac/tests/hdr-rendition-reset.sh 覆盖）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/build-env.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-rendition-ui.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="$(rawlab_mac_sdk_path)"
swiftc -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/HDRAdjustmentTransfer.swift" "$ROOT/Shared/HDRDisplay.swift" \
    "$ROOT/Shared/Native/HDRCanvas.swift" "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLabMac/tests/HDRRenditionUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
