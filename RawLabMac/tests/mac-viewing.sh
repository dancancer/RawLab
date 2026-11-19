#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-mac-viewing.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
 "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacPhotoViewport.swift" "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" "$ROOT/RawLabMac/Sources/Presentation/MacViewingState.swift" "$ROOT/RawLabMac/tests/MacViewingTests.swift" -o "$OUT/test"
"$OUT/test"
