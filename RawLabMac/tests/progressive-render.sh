#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="$(mktemp -d /tmp/rawlab-progressive-render.XXXXXX)"
RAW="${1:-${RAWLAB_TEST_RAW:-}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an external RAW path'; exit 1; }
LUT="${2:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}"

swiftc -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Engine.swift" \
    "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments.swift" \
    "$ROOT/RawLabMac/Sources/RenderScheduling.swift" \
    "$ROOT/RawLabMac/Sources/LookLibrary.swift" \
    "$ROOT/RawLabMac/Sources/EditorModel.swift" \
    "$ROOT/RawLabMac/tests/ProgressiveRenderTests.swift" \
    "$BUILD/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    -o "$OUT/progressive-render"

if [[ "${RUN_PROGRESSIVE_RENDER:-0}" != "1" ]]; then
    echo "PASS: progressive render integration binary compiled ($OUT/progressive-render)"
    echo "Set RUN_PROGRESSIVE_RENDER=1 to execute RAW renders."
    exit 0
fi

"$OUT/progressive-render" "$RAW" "$LUT"
