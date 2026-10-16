#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/RawLabMac/build-env.sh"
BASE="$RAWLAB_DEPS_BASE"
REVISION="7f61bf592f3c470b2a7d8199431fde821d7253ac"
SOURCES="$BASE/$ARCH/sources"
rawlab_fetch "wavelib-$REVISION.tar.gz" 62247c314bc98d395b0558882b37254b653753f0e1635cd5bd9807b27c79f96e \
    "https://github.com/rafat/wavelib/archive/$REVISION.tar.gz" "wavelib-$REVISION"
cmake -S "$ROOT/lutools/cmake/wavelib" -B "$BASE/$ARCH/wavelib" \
    -DWAVELIB_SOURCE_DIR="$SOURCES/wavelib-$REVISION" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$RAWLAB_DEPENDENCY_PREFIX"
cmake --build "$BASE/$ARCH/wavelib" -j "${JOBS:-$(sysctl -n hw.ncpu)}"
cmake --install "$BASE/$ARCH/wavelib"
