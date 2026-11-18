#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-horizontal-picker.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/RawLabMac/Sources/Inputs/HorizontalPicker.swift" "$ROOT/RawLabMac/tests/HorizontalPickerTests.swift" \
    -framework SwiftUI -framework Foundation -o "$OUT/test"
"$OUT/test"
