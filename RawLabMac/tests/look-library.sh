#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="$(mktemp -d /tmp/rawlab-look-library.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=("$ROOT/RawLabMac/tests/LookLibraryTests.swift")
if [ -f "$ROOT/RawLabMac/Sources/LookLibrary.swift" ]; then
    SOURCES+=("$ROOT/RawLabMac/Sources/LookLibrary.swift")
fi
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$BUILD/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz \
    -framework Metal -o "$OUT/look-library"
"$OUT/look-library"
