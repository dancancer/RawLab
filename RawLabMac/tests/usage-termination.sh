#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-usage-termination.XXXXXX)"
trap 'rm -r "$OUT"' EXIT
for mode in default local; do
    flags=(-swift-version 5 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
           -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}")
    if [[ "$mode" == local ]]; then flags+=(-D RAWLAB_RUM_LOCAL); fi
    swiftc "${flags[@]}" \
        "$ROOT/RawLabMac/Sources/MacGeometryWindowGuard.swift" \
        "$ROOT/RawLabMac/tests/UsageTerminationTests.swift" -o "$OUT/$mode"
    "$OUT/$mode"
done
