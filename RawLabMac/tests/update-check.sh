#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-update-check.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -swift-version 5 -sdk "$SDK" \
  "$ROOT/RawLabMac/Sources/UpdateRelease.swift" "$ROOT/RawLabMac/tests/UpdateReleaseTests.swift" -o "$OUT/check"
"$OUT/check"
swiftc -swift-version 5 -sdk "$SDK" \
  "$ROOT/RawLabMac/Sources/UpdateRelease.swift" "$ROOT/RawLabMac/Sources/UpdateChecker.swift" \
  "$ROOT/RawLabMac/tests/UpdateCheckerTests.swift" -o "$OUT/check-state"
"$OUT/check-state"
