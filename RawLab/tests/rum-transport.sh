#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-rum-transport-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -D DEBUG -sdk "$SDK" \
    "$ROOT/Shared/UsageAnalytics.swift" \
    "$ROOT/RawLab/RawLab/Core/Usage/RUMConfiguration.swift" \
    "$ROOT/RawLab/RawLab/Core/Usage/RUMUsageTransport.swift" \
    "$ROOT/RawLab/tests/RUMTransportTests.swift" \
    -o "$OUT/tests"
"$OUT/tests"
