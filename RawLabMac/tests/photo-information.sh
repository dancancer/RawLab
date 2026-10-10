#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-photo-info.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    "$ROOT/Shared/PhotoInformation.swift" "$ROOT/RawLabMac/tests/PhotoInformationTests.swift" -o "$OUT/test"
"$OUT/test"
