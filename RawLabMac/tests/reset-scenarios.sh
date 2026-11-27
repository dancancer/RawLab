#!/bin/bash
# P1 第③步：重置场景向量（Shared/fixtures/reset-scenarios-v1.json）macOS 消费入口。
# 文件集与 adjustment-transfer.sh 相同（重置规则就在 Adjustments.swift / AdjustmentTypes.swift 内）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-reset-scenarios
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization \
    "${RAWLAB_RESET_TEST_SOURCE:-$ROOT/RawLabMac/tests/ResetScenarioTests.swift}" \
    -framework Foundation -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
