#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-usage-transport.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
set --
if [ "$(uname -s)" = Darwin ]; then
    set -- -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
        -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}"
fi
swiftc "$@" -swift-version 5 "$ROOT/Shared/UsageAnalytics.swift" "$ROOT/Shared/SerialUsageTransport.swift" \
    "$ROOT/Shared/tests/UsageTransportTests.swift" -o "$OUT/tests"
"$OUT/tests"
