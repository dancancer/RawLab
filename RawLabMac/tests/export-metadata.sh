#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-export-metadata.XXXXXX)"
SOURCES=("$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/RawLabMac/Sources/Adjustments.swift")
if [ -f "$ROOT/Shared/ExportMetadata.swift" ]; then
    SOURCES+=("$ROOT/Shared/ExportMetadata.swift")
fi
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/RawLabMac/tests/ExportMetadataTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz \
    -framework AppKit -framework ImageIO -framework Metal -o "$OUT/export-metadata"
"$OUT/export-metadata" "$ROOT" "$OUT"
echo "Artifacts: $OUT"
