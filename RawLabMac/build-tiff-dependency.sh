#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
BASE="$ROOT/build/macos15-deps"
PREFIX="$BASE/$ARCH/install"
VERSION=4.7.1
SOURCE="$BASE/sources/tiff-$VERSION"
ARCHIVE="$BASE/sources/tiff-$VERSION.tar.gz"
mkdir -p "$BASE/sources"
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 "https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz" -o "$ARCHIVE"
fi
printf '%s  %s\n' f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69 "$ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$SOURCE" ]; then tar -xf "$ARCHIVE" -C "$BASE/sources"; fi
cmake -S "$SOURCE" -B "$BASE/$ARCH/tiff" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-cxx=OFF \
    -Djpeg=OFF -Dlerc=OFF -Dwebp=OFF -Dzstd=OFF -Dlzma=OFF -Dlibdeflate=OFF \
    -Djbig=OFF -Dold-jpeg=OFF
cmake --build "$BASE/$ARCH/tiff" --target tiff -j "${JOBS:-6}"
cmake --install "$BASE/$ARCH/tiff"
mkdir -p "$PREFIX/share/licenses/libtiff"
cp "$SOURCE/LICENSE.md" "$PREFIX/share/licenses/libtiff/"
