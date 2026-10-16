#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-usage-transport.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/UsageAnalytics.swift" "$ROOT/Shared/SerialUsageTransport.swift" \
    "$ROOT/Shared/tests/UsageTransportTests.swift" -o "$OUT/tests"
"$OUT/tests"
