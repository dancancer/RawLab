#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-adjustments.XXXXXX)"
SOURCES=("$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/Shared/ExportMetadata.swift")
if [ -f "$ROOT/RawLabMac/Sources/Adjustments.swift" ]; then
    SOURCES+=("$ROOT/RawLabMac/Sources/Adjustments.swift")
fi
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/RawLabMac/tests/AdjustmentTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/adjustments"
SAMPLES=()
if [ -n "${RAWLAB_TEST_RAW:-}" ]; then SAMPLES+=("$RAWLAB_TEST_RAW"); fi
for raw in "$ROOT"/lutools/examples/*; do
    case "$raw" in
        *.[Aa][Rr][Ww]|*.[Dd][Nn][Gg]|*.[Nn][Ee][Ff]|*.[Cc][Rr]2|*.[Cc][Rr]3|*.[Rr][Aa][Ff]|*.[Rr][Ww]2|*.[Oo][Rr][Ff]) SAMPLES+=("$raw") ;;
    esac
done
test "${#SAMPLES[@]}" -gt 0 || { echo 'Set RAWLAB_TEST_RAW to an external RAW path'; exit 1; }
for raw in "${SAMPLES[@]}"; do
    "$OUT/adjustments" "$ROOT" "$OUT/$(basename "$raw")" "$raw"
done
echo "PASS: ${#SAMPLES[@]} RAW fixtures; artifacts in $OUT"
