#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-rum-local-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/RawLabMac/Sources/RUMPCConfiguration.swift" \
    "$ROOT/RawLabMac/tests/RUMPCConfigurationTests.swift" -o "$OUT/tests"
"$OUT/tests"
