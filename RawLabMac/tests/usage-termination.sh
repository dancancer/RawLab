#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-usage-termination
# 三种编译：不带 SDK、正式带 SDK、本地验证（在带 SDK 基础上换配置来源）
for mode in default rum local; do
    flags=()
    rum_local=0
    if [[ "$mode" != default ]]; then flags+=(-D RAWLAB_RUM); fi
    if [[ "$mode" == local ]]; then flags+=(-D RAWLAB_RUM_LOCAL); rum_local=1; fi
    rawlabkit_flags link "$OUT/swiftpm" macos "$rum_local"
    rawlab_mac_swiftc ${flags[@]+"${flags[@]}"} "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
        "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift" \
        "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
        "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" \
        "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
        "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" \
        "$ROOT/RawLabMac/Sources/System/Updates/DesktopUpdateController.swift" \
        "$ROOT/RawLabMac/Sources/System/MacGeometryWindowGuard.swift" \
        "$ROOT/RawLabMac/tests/UsageTerminationTests.swift" -o "$OUT/$mode"
    "$OUT/$mode"
done
