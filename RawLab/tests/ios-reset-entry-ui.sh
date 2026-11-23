#!/bin/bash
# 表示层/模型重置入口断言：30 条检查不依赖 macOS 辅助功能授权，按 Q14 无条件编译并
# 真跑（本地、CI models 清单与发布前一致）。仅两处 `if axTrusted` AX 分支受闸状态
# 影响，三态在 30 条模型断言全部跑完后于 Swift 末尾统一判定（闸 FAIL 不抢跑遮蔽模型
# 失败；文案与 ax-gate.sh 同源，契约见 docs/process/ci.md）：AX 在场全跑；无 AX 未设
# 档 SKIP+::warning:: exit 0；无 AX 且 RAWLAB_REQUIRE_AX=1 FAIL exit 1。桌面/发布前
# 真跑 AX 分支须带 RAWLAB_REQUIRE_AX=1。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-reset-entry-ui
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorToolDraft.swift" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorWorkspaceResetControl.swift" \
    "$ROOT/RawLab/tests/IOSResetEntryUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
