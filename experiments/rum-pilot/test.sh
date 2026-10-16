#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-rum-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" \
    "$ROOT/experiments/rum-pilot/PilotConfiguration.swift" \
    "$ROOT/experiments/rum-pilot/PilotConfigurationTests.swift" -o "$OUT/test"
"$OUT/test"
