#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-lut-preview.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/DCPCompiler.swift" "$ROOT/Shared/LookLibrary.swift" \
    "$ROOT/Shared/LUTCompatibilityPreview.swift" "$ROOT/RawLabMac/tests/LUTPreviewTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/lut-preview"
"$OUT/lut-preview"
