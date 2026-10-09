#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-denoise-model.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments.swift" "$ROOT/RawLabMac/Sources/EditorModel.swift" \
  "$ROOT/RawLabMac/Sources/LookLibrary.swift" "$ROOT/RawLabMac/Sources/RenderScheduling.swift" \
  "$ROOT/RawLabMac/Sources/FileLibrary.swift" "$ROOT/RawLabMac/tests/DenoiseModelTests.swift" \
  "$ROOT/lutools/build-macos/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:?Pass a RAW fixture}"
