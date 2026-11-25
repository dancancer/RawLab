#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_native_env
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
rawlab_mac_make_temp_dir TEMP rawlab-hdr-bridge
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
rawlabnative_flags link "$BUILD/swiftpm" macos 0 types_only
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Native/HDRPresentation.swift" \
    "$ROOT/Shared/Native/HDRSource.swift" "$ROOT/Shared/Native/HDRImage.swift" \
    "$ROOT/RawLabMac/tests/HDRBridgeTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw_r rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz -framework Metal -o "$TEMP/test"
"$TEMP/test" "$TEMP/source.jpg" "$ROOT/lutools/tests/fixtures/bayer-demosaic.dng" "$@"
