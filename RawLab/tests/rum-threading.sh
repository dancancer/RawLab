#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-ios-rum-threading-tests.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -D DEBUG -sdk "$SDK" \
    "$ROOT/RawLab/RawLab/Core/Usage/RUMUsageTransport.swift" \
    "$ROOT/RawLab/tests/RUMThreadingTests.swift" \
    -o "$OUT/tests"
"$OUT/tests"
