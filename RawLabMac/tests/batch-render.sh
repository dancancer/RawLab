#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
INPUT="${1:?Pass a real RAW fixture}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-batch-render.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments.swift" "$ROOT/RawLabMac/Sources/EditPersistence.swift" \
  "$ROOT/RawLabMac/Sources/BatchExport.swift" "$ROOT/RawLabMac/Sources/BatchExportModel.swift" \
  "$ROOT/RawLabMac/Sources/FileLibrary.swift" "$ROOT/RawLabMac/tests/BatchRenderTests.swift" \
  "$ROOT/lutools/build-macos/libsony2fuji_core.a" -L "$(pkg-config --variable=libdir libraw)" \
  -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$INPUT"
