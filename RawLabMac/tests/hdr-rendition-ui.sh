#!/bin/bash
# 本地/发布前手工 UI 检查（依赖 macOS 辅助功能 AXUIElement 授权，CI 不执行；
# CI 模型门禁改由不依赖辅助功能权限的 RawLabMac/tests/hdr-rendition-reset.sh 覆盖）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/RawLabMac/tests/ax-gate.sh"
rawlab_ax_gate
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-hdr-rendition-ui
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Native/HDRCanvas.swift" "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLabMac/tests/HDRRenditionUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
