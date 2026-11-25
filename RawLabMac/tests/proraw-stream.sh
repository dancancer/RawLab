#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_native_env
if [ "$#" -eq 0 ]; then echo 'Usage: proraw-stream.sh <ProRAW.dng>...' >&2; exit 2; fi
rawlab_mac_make_temp_dir TEMP rawlab-proraw-stream
rawlabnative_flags link "$TEMP/swiftpm" macos 0 types_only
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Native/HDRSource.swift" "$ROOT/Shared/Native/HDRImage.swift" \
    "$ROOT/RawLabMac/tests/ProRAWStreamTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw_r rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz -framework Metal -o "$TEMP/test"
"$TEMP/test" "$@"
