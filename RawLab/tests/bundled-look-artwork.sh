#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
RESOURCES="${1:?Pass the built iOS resource bundle or app resource directory}"
DEVICE="${2:?Pass an explicit booted simulator UDID}"
rawlab_ios_make_temp_dir OUT rawlab-look-artwork
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc -parse-as-library "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    "$ROOT/RawLab/tests/BundledLookArtworkTests.swift" -o "$OUT/artwork"
xcrun simctl spawn "$DEVICE" "$OUT/artwork" "$RESOURCES"
