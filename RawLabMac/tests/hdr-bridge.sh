#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-bridge.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
"$BUILD/hdr_image_tests" --fixture "$TEMP/source.jpg"
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HDRRecipe.swift" "$ROOT/Shared/HDRDisplay.swift" \
    "$ROOT/Shared/Native/HDRPresentation.swift" \
    "$ROOT/Shared/Native/HDRRequest.swift" "$ROOT/Shared/Native/HDRSource.swift" "$ROOT/Shared/Native/HDRImage.swift" \
    "$ROOT/RawLabMac/tests/HDRBridgeTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz -framework Metal -o "$TEMP/test"
"$TEMP/test" "$TEMP/source.jpg"
