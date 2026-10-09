#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
BASE="$ROOT/build/macos15-deps"
SOURCES="$BASE/sources"
PREFIX="$BASE/$ARCH/install"
BUILD="$BASE/$ARCH/opencv"
mkdir -p "$SOURCES"
fetch() {
    local name="$1" sum="$2" url="$3"
    if [ ! -f "$SOURCES/$name.tar.gz" ]; then curl -fL --retry 2 "$url" -o "$SOURCES/$name.tar.gz"; fi
    printf '%s  %s\n' "$sum" "$SOURCES/$name.tar.gz" | shasum -a 256 -c -
    if [ ! -d "$SOURCES/$name" ]; then tar -xf "$SOURCES/$name.tar.gz" -C "$SOURCES"; fi
}
fetch opencv-4.12.0 44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d \
    https://github.com/opencv/opencv/archive/refs/tags/4.12.0.tar.gz
fetch opencv_contrib-4.12.0 4197722b4c5ed42b476d42e29beb29a52b6b25c34ec7b4d589c3ae5145fee98e \
    https://github.com/opencv/opencv_contrib/archive/refs/tags/4.12.0.tar.gz
cmake -S "$SOURCES/opencv-4.12.0" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DOPENCV_EXTRA_MODULES_PATH="$SOURCES/opencv_contrib-4.12.0/modules" \
    -DBUILD_LIST=core,imgproc,ximgproc -DBUILD_SHARED_LIBS=ON -DOPENCV_GENERATE_PKGCONFIG=ON \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
    -DBUILD_opencv_dnn=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
    -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_LAPACK=OFF -DWITH_EIGEN=OFF \
    -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_AVFOUNDATION=OFF \
    -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENEXR=OFF \
    -DWITH_JASPER=OFF -DWITH_OPENJPEG=OFF -DWITH_AVIF=OFF -DWITH_GDAL=OFF \
    -DWITH_PROTOBUF=OFF -DWITH_ITT=OFF -DWITH_VTK=OFF -DWITH_TBB=OFF \
    -DOPENCV_ENABLE_NONFREE=OFF
cmake --build "$BUILD" -j "${JOBS:-$(sysctl -n hw.ncpu)}"
cmake --install "$BUILD"
mkdir -p "$PREFIX/share/licenses/opencv4"
cp "$SOURCES/opencv-4.12.0/LICENSE" "$PREFIX/share/licenses/opencv4/OpenCV-LICENSE"
cp "$SOURCES/opencv_contrib-4.12.0/LICENSE" "$PREFIX/share/licenses/opencv4/contrib-LICENSE"
sed -n '1,35p' "$SOURCES/opencv_contrib-4.12.0/modules/ximgproc/src/guided_filter.cpp" \
    > "$PREFIX/share/licenses/opencv4/guided-filter-LICENSE"
