#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/RawLabMac/build-env.sh"

if ! rawlab_macos_version_at_most "14.0" "$MACOSX_DEPLOYMENT_TARGET"; then
    echo "macOS Lensfun dependencies require deployment target 14.0 or newer: $MACOSX_DEPLOYMENT_TARGET" >&2
    exit 2
fi

SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
CC="${CC:-$(xcrun -f clang)}"
CXX="${CXX:-$(xcrun -f clang++)}"
AR="${AR:-$(xcrun -f ar)}"
PYTHON="${PYTHON:-python3}"
CMAKE="${CMAKE:-$(command -v cmake)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
BUILD="$RAWLAB_LENS_BASE/$ARCH"
GLIB_BUILD="$RAWLAB_DEPS_BASE/$ARCH/glib"
LOG="${RAWLAB_LENS_LOG:-/tmp/rawlab-lens-dependency-$MACOSX_DEPLOYMENT_TARGET-$ARCH.log}"
exec > >(tee "$LOG") 2>&1

"$PYTHON" "$ROOT/lutools/cmake/build-lens-dependencies.py" \
    --build "$BUILD" --glib-build "$GLIB_BUILD" \
    --prefix "$RAWLAB_LENS_PREFIX" --glib-prefix "$RAWLAB_DEPENDENCY_PREFIX" \
    --platform macos --arch "$ARCH" --cc "$CC" --cxx "$CXX" --ar "$AR" \
    --cmake "$CMAKE" --sysroot "$SDKROOT" --minimum "$MACOSX_DEPLOYMENT_TARGET" \
    --source-cache "$RAWLAB_SOURCE_CACHE" --jobs "$JOBS"

PKG_CONFIG_PATH="$RAWLAB_LENS_PREFIX/lib/pkgconfig:$RAWLAB_DEPENDENCY_PREFIX/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$RAWLAB_LENS_PREFIX/lib/pkgconfig:$RAWLAB_DEPENDENCY_PREFIX/lib/pkgconfig" \
    pkg-config --exists glib-2.0 lensfun

if [ "$(PKG_CONFIG_PATH="$RAWLAB_LENS_PREFIX/lib/pkgconfig:$RAWLAB_DEPENDENCY_PREFIX/lib/pkgconfig" \
    pkg-config --variable=prefix glib-2.0)" != "$RAWLAB_DEPENDENCY_PREFIX" ]; then
    echo "GLib pkg-config prefix is not target-built: $RAWLAB_DEPENDENCY_PREFIX" >&2
    exit 1
fi
if [ "$(PKG_CONFIG_PATH="$RAWLAB_LENS_PREFIX/lib/pkgconfig:$RAWLAB_DEPENDENCY_PREFIX/lib/pkgconfig" \
    pkg-config --variable=prefix lensfun)" != "$RAWLAB_LENS_PREFIX" ]; then
    echo "Lensfun pkg-config prefix is not target-built: $RAWLAB_LENS_PREFIX" >&2
    exit 1
fi

check_binary() {
    local binary="$1" minimum
    lipo "$binary" -verify_arch "$ARCH" >/dev/null
    if otool -L "$binary" | grep -Eq '/opt/homebrew|/usr/local/Cellar'; then
        echo "Host package-manager dependency leaked into $binary" >&2
        exit 1
    fi
    minimum="$(otool -l "$binary" | awk '
        $1 == "minos" { print $2; exit }
        $1 == "LC_VERSION_MIN_MACOSX" { version_min = 1; next }
        version_min && $1 == "version" { print $2; exit }
    ')"
    if [ -z "$minimum" ] || ! rawlab_macos_version_at_most "$minimum" "$MACOSX_DEPLOYMENT_TARGET"; then
        echo "Deployment target check failed for $binary: ${minimum:-missing}" >&2
        exit 1
    fi
}

while IFS= read -r binary; do check_binary "$binary"; done < <(
    find "$RAWLAB_DEPENDENCY_PREFIX/lib" "$RAWLAB_LENS_PREFIX/lib" \
        -maxdepth 1 -type f -name '*.dylib' -print | sort
)
test -f "$RAWLAB_LENS_PREFIX/libraries.json"
echo "Built target Lensfun/GLib dependencies for $ARCH (macOS $MACOSX_DEPLOYMENT_TARGET)"
