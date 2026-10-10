#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
OUT="$(mktemp -d /tmp/rawlab-tone-regions.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/AIColorRecipe.swift" "$ROOT/RawLabMac/Sources/AIColorLook.swift" \
    "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/RawLabMac/Sources/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/EditPersistence.swift" "$ROOT/RawLabMac/Sources/BatchExport.swift" \
    "$ROOT/RawLabMac/Sources/FileLibrary.swift" "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/experiments/ai-color-match/tone_regions.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib) -lc++ -lz \
    -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:-$ROOT/experiments/ai-color-match/tone_regions.json}" "${2:-$ROOT/output/adaptive-tone-regions}"
