#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="${RAWLAB_PERSPECTIVE_OUTPUT_DIR:-$(mktemp -d /tmp/rawlab-mac-perspective.XXXXXX)}"
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an existing RAW path' >&2; exit 1; }
test -f "$BUILD/libsony2fuji_core.a" || { echo 'Build the Mac core first: bash RawLabMac/build.sh' >&2; exit 1; }
mkdir -p "$OUT"
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/tests/MacPerspectiveIntegrationTests.swift" \
    "${CORE_LINK[@]}" $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)" \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$RAW" "$OUT"
echo "Artifacts: $OUT"
