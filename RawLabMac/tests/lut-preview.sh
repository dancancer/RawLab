#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
rawlab_mac_native_env
rawlab_mac_make_temp_dir OUT rawlab-lut-preview
rawlabnative_flags link "$OUT/swiftpm" macos 0 all
rawlab_mac_native_link_flags NATIVE_LINK
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${HDR_SWIFT_SOURCES[@]}" \
    "$ROOT/Shared/LUTCompatibilityPreview.swift" "$ROOT/RawLabMac/tests/LUTPreviewTests.swift" "${NATIVE_LINK[@]}" -o "$OUT/lut-preview"
"$OUT/lut-preview" "$@"
