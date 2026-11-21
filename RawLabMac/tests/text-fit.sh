#!/bin/bash
# 各语言界面文字放得下：配方卡片说明、工具名等，按 SwiftUI 实际排版测量
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-text-fit
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/RawLabMac/Sources/Editor/View/AdjustmentPanelLayout.swift" \
    "$ROOT/RawLabMac/tests/TextFitTests.swift" -framework SwiftUI -framework AppKit -o "$OUT/text-fit"
"$OUT/text-fit" "$ROOT"
