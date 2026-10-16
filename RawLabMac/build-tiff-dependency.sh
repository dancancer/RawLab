#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/RawLabMac/build-env.sh"
BASE="$RAWLAB_DEPS_BASE"
PREFIX="$RAWLAB_DEPENDENCY_PREFIX"
VERSION=4.7.1
SOURCES="$BASE/$ARCH/sources"
SOURCE="$SOURCES/tiff-$VERSION"
rawlab_fetch "tiff-$VERSION.tar.gz" f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69 \
    "https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz" "tiff-$VERSION"
cmake -S "$SOURCE" -B "$BASE/$ARCH/tiff" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-cxx=OFF \
    -Djpeg=OFF -Dlerc=OFF -Dwebp=OFF -Dzstd=OFF -Dlzma=OFF -Dlibdeflate=OFF \
    -Djbig=OFF -Dold-jpeg=OFF
cmake --build "$BASE/$ARCH/tiff" --target tiff -j "${JOBS:-6}"
cmake --install "$BASE/$ARCH/tiff"
mkdir -p "$PREFIX/share/licenses/libtiff"
cp "$SOURCE/LICENSE.md" "$PREFIX/share/licenses/libtiff/"
