#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-usage-termination.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
# 三种编译：不带 SDK、正式带 SDK、本地验证（在带 SDK 基础上换配置来源）
for mode in default rum local; do
    flags=(-swift-version 5 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
           -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}")
    if [[ "$mode" != default ]]; then flags+=(-D RAWLAB_RUM); fi
    if [[ "$mode" == local ]]; then flags+=(-D RAWLAB_RUM_LOCAL); fi
    swiftc "${flags[@]}" \
        "$ROOT/Shared/Localization.swift" \
        "$ROOT/RawLabMac/Sources/Inputs/ParameterPrecision.swift" \
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
