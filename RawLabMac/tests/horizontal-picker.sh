#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-horizontal-picker.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/RawLabMac/Sources/HorizontalPicker.swift" "$ROOT/RawLabMac/tests/HorizontalPickerTests.swift" \
    -framework SwiftUI -framework Foundation -o "$OUT/test"
"$OUT/test"
