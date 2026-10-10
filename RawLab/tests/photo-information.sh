#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-photo-information.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -sdk "$SDK" \
    "$ROOT/Shared/PhotoInformation.swift" \
    "$ROOT/RawLab/tests/PhotoInformationTests.swift" \
    -o "$OUT/photo-information"
"$OUT/photo-information"
