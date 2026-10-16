#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-usage-tests.XXXXXX")"
trap 'rm -r "$TMP"' EXIT
set --
if [ "$(uname -s)" = Darwin ]; then
    set -- -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
        -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}"
fi
swiftc "$@" -swift-version 5 "$ROOT/Shared/UsageAnalytics.swift" \
  "$ROOT/Shared/tests/UsageAnalyticsTests.swift" -o "$TMP/tests"
"$TMP/tests"
