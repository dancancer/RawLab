#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-lens-draft-controls
rawlab_mac_native_env
RPATHS=()
for dependency in libraw_r opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/test" -- \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLabMac/Sources/Lens/MacLensPresentation.swift" \
    "$ROOT/RawLabMac/tests/MacLensDraftControlsTests.swift" "${RPATHS[@]}"
"$OUT/test"
