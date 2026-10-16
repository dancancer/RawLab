#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-rum-local-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -D DEBUG -sdk "$SDK" \
    "$ROOT/RawLab/RawLab/Core/Usage/RUMLocalConfiguration.swift" \
    "$ROOT/RawLab/tests/RUMLocalConfigurationTests.swift" \
    -o "$OUT/tests"
"$OUT/tests"
