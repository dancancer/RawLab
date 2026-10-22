#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="${RAWLAB_VIEWING_OUTPUT_DIR:-$(mktemp -d /tmp/rawlab-mac-viewing-model.XXXXXX)}"
if [ -z "${RAWLAB_VIEWING_OUTPUT_DIR:-}" ]; then trap 'rm -rf "$OUT"' EXIT; fi
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$OUT"
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "$OUT/ModuleCache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/tests/MacViewingModelTests.swift" \
    "$BUILD/libsony2fuji_core.a" $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)" \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:?Pass RAW fixture}" "$OUT"
