#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${RAWLAB_TEST_RAW:?Pass an external supported X3F fixture}"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
OUT="$(mktemp -d /tmp/rawlab-mac-x3f.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "$OUT/ModuleCache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT"/Shared/Native/*.swift \
    "$ROOT/RawLabMac/tests/X3FWorkflowTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$RAWLAB_TEST_RAW" "$BUILD/sony2fuji"
