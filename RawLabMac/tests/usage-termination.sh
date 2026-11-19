#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-usage-termination.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
# 三种编译：不带 SDK、正式带 SDK、本地验证（在带 SDK 基础上换配置来源）
for mode in default rum local; do
    SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    flags=(-swift-version 5 -sdk "$SDK"
           -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}")
    rum_local=0
    if [[ "$mode" != default ]]; then flags+=(-D RAWLAB_RUM); fi
    if [[ "$mode" == local ]]; then flags+=(-D RAWLAB_RUM_LOCAL); rum_local=1; fi
    rawlabkit_flags link "$OUT/swiftpm" macos "$rum_local"
    swiftc "${flags[@]}" "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
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
