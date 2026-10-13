#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
BASE="$ROOT/build/lensfun"
SOURCE="$BASE/sources/lensfun-0.3.4"
ARCHIVE="$BASE/sources/lensfun-0.3.4.tar.gz"
PREFIX="$BASE/$ARCH/install"
mkdir -p "$BASE/sources"
if ! pkg-config --exists glib-2.0; then
    echo "Lensfun requires GLib development files (brew install glib)." >&2
    exit 1
fi
GLIB_LIB="$(pkg-config --variable=libdir glib-2.0)/libglib-2.0.dylib"
if ! lipo -verify_arch "$ARCH" "$GLIB_LIB" >/dev/null 2>&1; then
    echo "GLib must support $ARCH. Set PKG_CONFIG_PATH to a target-architecture GLib build." >&2
    exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 https://github.com/lensfun/lensfun/archive/refs/tags/v0.3.4.tar.gz -o "$ARCHIVE"
fi
printf '%s  %s\n' dafb39c08ef24a0e2abd00d05d7341b1bf1f0c38bfcd5a4c69cf5f0ecb6db112 "$ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$SOURCE" ]; then tar -xf "$ARCHIVE" -C "$BASE/sources"; fi
cmake -S "$SOURCE" -B "$BASE/$ARCH/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DBUILD_STATIC=OFF -DBUILD_TESTS=OFF -DBUILD_LENSTOOL=OFF -DBUILD_DOC=OFF \
    -DBUILD_FOR_SSE=OFF -DBUILD_FOR_SSE2=OFF -DPYTHON=OFF -DINSTALL_PYTHON_MODULE=OFF -DINSTALL_HELPER_SCRIPTS=OFF
cmake --build "$BASE/$ARCH/build" -j "${JOBS:-6}"
cmake --install "$BASE/$ARCH/build"
