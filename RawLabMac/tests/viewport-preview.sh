#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
OUT="$(mktemp -d /tmp/rawlab-viewport-preview.XXXXXX)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/tests/ViewportPreviewTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    -o "$OUT/test"
"$OUT/test" "$RAW" "$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube" "$OUT" "${@:2}"
echo "Artifacts: $OUT"
