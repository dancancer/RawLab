#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-rum-local-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc "$ROOT/RawLabMac/Sources/RUMPCConfiguration.swift" \
    "$ROOT/RawLabMac/tests/RUMLocalConfigurationTests.swift" -o "$OUT/tests"
"$OUT/tests"
