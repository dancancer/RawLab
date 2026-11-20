#!/bin/bash
# 不依赖辅助功能（AX）授权的 HDR 渲染重置按钮表示模型与真实布局契约测试（供 CI 模型套件执行）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-hdr-rendition-reset
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    "$ROOT/Shared/Native/HDRCanvas.swift" "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLabMac/tests/HDRRenditionResetTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
