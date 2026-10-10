#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
BASE="$ROOT/build/macos15-deps"
REVISION="7f61bf592f3c470b2a7d8199431fde821d7253ac"
SOURCES="$BASE/sources"
ARCHIVE="$SOURCES/wavelib-$REVISION.tar.gz"
mkdir -p "$SOURCES"
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 "https://github.com/rafat/wavelib/archive/$REVISION.tar.gz" -o "$ARCHIVE"
fi
printf '%s  %s\n' '62247c314bc98d395b0558882b37254b653753f0e1635cd5bd9807b27c79f96e' "$ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$SOURCES/wavelib-$REVISION" ]; then tar -xf "$ARCHIVE" -C "$SOURCES"; fi
cmake -S "$ROOT/lutools/cmake/wavelib" -B "$BASE/$ARCH/wavelib" \
    -DWAVELIB_SOURCE_DIR="$SOURCES/wavelib-$REVISION" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
    -DCMAKE_INSTALL_PREFIX="$BASE/$ARCH/install"
cmake --build "$BASE/$ARCH/wavelib" -j "${JOBS:-$(sysctl -n hw.ncpu)}"
cmake --install "$BASE/$ARCH/wavelib"
