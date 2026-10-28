#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=$(mktemp -d /tmp/rawlab-sparkle-adapter.XXXXXX)
trap 'rm -rf "$OUT"' EXIT
FRAMEWORK="$(bash "$ROOT/RawLabMac/prepare-sparkle.sh")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
swiftc -swift-version 5 -warnings-as-errors -sdk "${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" \
    -F "$(dirname "$FRAMEWORK")" -framework Sparkle -Xlinker -rpath -Xlinker "$(dirname "$FRAMEWORK")" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdatePackage.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/SparkleUpdateAdapter.swift" "$ROOT/RawLabMac/tests/SparkleUpdateAdapterTests.swift" -o "$OUT/test"
"$OUT/test"
