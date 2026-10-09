#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCH" >&2; exit 1 ;; esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
BASE="$ROOT/build/macos15-deps"
SOURCES="$BASE/sources"
BUILD="$BASE/$ARCH"
PREFIX="$BUILD/install"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
mkdir -p "$SOURCES" "$PREFIX" "$BUILD/lcms"

fetch() {
    local archive="$1" checksum="$2" url="$3" directory="$4"
    if [ ! -f "$SOURCES/$archive" ]; then
        curl -fL --retry 2 "$url" -o "$SOURCES/$archive"
    fi
    printf '%s  %s\n' "$checksum" "$SOURCES/$archive" | shasum -a 256 -c -
    if [ ! -d "$SOURCES/$directory" ]; then tar -xf "$SOURCES/$archive" -C "$SOURCES"; fi
}

fetch libjpeg-turbo-3.1.3.tar.gz 3a13a5ba767dc8264bc40b185e41368a80d5d5f945944d1dbaa4b2fb0099f4e5 \
    https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.3.tar.gz libjpeg-turbo-3.1.3
fetch jasper-4.2.8.tar.gz 987e8c8b4afcff87553833b6f0fa255b5556a0ecc617b45ee1882e10c1b5ec14 \
    https://github.com/jasper-software/jasper/archive/refs/tags/version-4.2.8.tar.gz jasper-version-4.2.8
fetch lcms2.17.tar.gz 6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418 \
    https://github.com/mm2/Little-CMS/archive/refs/tags/lcms2.17.tar.gz Little-CMS-lcms2.17
fetch openmp-21.1.8.src.tar.xz 856b023748b41ac7b2c83fd8e9f765ff48a4df2fe6777d2811ef7c7ed8f2f977 \
    https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/openmp-21.1.8.src.tar.xz openmp-21.1.8.src
fetch cmake-21.1.8.src.tar.xz 85735f20fd8c81ecb0a09abb0c267018475420e93b65050cc5b7634eab744de9 \
    https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/cmake-21.1.8.src.tar.xz cmake-21.1.8.src
fetch LibRaw-0.22.2.tar.gz de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa \
    https://www.libraw.org/data/LibRaw-0.22.2.tar.gz LibRaw-0.22.2
fetch LibRaw-cmake-eb98e43.tar.gz 3cd218bf6d1254de86e27269541277fbfc5bae57a9002ce0b46fbe2a97088b43 \
    https://github.com/LibRaw/LibRaw-cmake/archive/eb98e4325aef2ce85d2eb031c2ff18640ca616d3.tar.gz LibRaw-cmake-eb98e4325aef2ce85d2eb031c2ff18640ca616d3
if [ ! -e "$SOURCES/cmake" ]; then ln -s cmake-21.1.8.src "$SOURCES/cmake"; fi
cmake -DLIBRAW_SOURCE_DIR="$SOURCES/LibRaw-0.22.2" -P "$ROOT/lutools/cmake/patch-libraw.cmake"

COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$SDK"
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" -DCMAKE_INSTALL_RPATH="$PREFIX/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON)

# NASM is optional for Intel JPEG acceleration; decoding remains available without it.
cmake -S "$SOURCES/libjpeg-turbo-3.1.3" -B "$BUILD/jpeg" "${COMMON[@]}" \
    -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_JPEG8=ON
cmake --build "$BUILD/jpeg" -j "$JOBS"
cmake --install "$BUILD/jpeg"

cmake -S "$SOURCES/jasper-version-4.2.8" -B "$BUILD/jasper" "${COMMON[@]}" \
    -DJAS_ENABLE_PROGRAMS=OFF -DJAS_ENABLE_DOC=OFF -DJAS_ENABLE_OPENGL=OFF \
    -DJAS_ENABLE_LIBHEIF=OFF -DJAS_ENABLE_SHARED=ON
cmake --build "$BUILD/jasper" -j "$JOBS"
cmake --install "$BUILD/jasper"

cmake -S "$SOURCES/openmp-21.1.8.src" -B "$BUILD/openmp" "${COMMON[@]}" \
    -DOPENMP_ENABLE_LIBOMPTARGET=OFF -DOPENMP_ENABLE_OMPT_TOOLS=OFF
cmake --build "$BUILD/openmp" -j "$JOBS"
cmake --install "$BUILD/openmp"

export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
export CFLAGS="-O3 -arch $ARCH -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
HOST="$ARCH-apple-darwin"
if [ "$ARCH" = arm64 ]; then HOST=aarch64-apple-darwin; fi
(
    cd "$BUILD/lcms"
    "$SOURCES/Little-CMS-lcms2.17/configure" --prefix="$PREFIX" --host="$HOST" \
        --disable-static --without-jpeg --without-tiff
    make -j "$JOBS"
    make install
)
cmake -S "$SOURCES/LibRaw-cmake-eb98e4325aef2ce85d2eb031c2ff18640ca616d3" \
    -B "$BUILD/libraw-cmake" "${COMMON[@]}" -DLIBRAW_PATH="$SOURCES/LibRaw-0.22.2" \
    -DBUILD_SHARED_LIBS=ON -DENABLE_EXAMPLES=OFF -DENABLE_OPENMP=ON \
    -DOpenMP_CXX_FLAGS="-Xpreprocessor -fopenmp" -DOpenMP_CXX_LIB_NAMES=omp \
    -DOpenMP_omp_LIBRARY="$PREFIX/lib/libomp.dylib" \
    -DZLIB_LIBRARY="$SDK/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$SDK/usr/include"
# LibRaw 0.22 removed the legacy RedCine decoder.
for feature in LCMS DNGDEFLATECODEC DNGLOSSYCODEC OPENMP; do
    grep -q "^#define LIBRAW_USE_$feature 1" "$BUILD/libraw-cmake/libraw_config.h" || {
        echo "Missing LibRaw feature: $feature" >&2; exit 1;
    }
done
cmake --build "$BUILD/libraw-cmake" -j "$JOBS"
cmake --install "$BUILD/libraw-cmake"
echo "Dependencies installed: $PREFIX"
