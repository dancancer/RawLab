#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
if [ "$#" -eq 0 ]; then echo 'Usage: proraw-stream.sh <ProRAW.dng>...' >&2; exit 2; fi
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-proraw-stream.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swiftc -O -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HDRRecipe.swift" \
    "$ROOT/Shared/Native/ProRAWSource.swift" "$ROOT/Shared/Native/ProRAWExport.swift" \
    "$ROOT/Shared/Native/HDRRequest.swift" "$ROOT/Shared/Native/HDRSource.swift" "$ROOT/Shared/Native/HDRImage.swift" \
    "$ROOT/RawLabMac/tests/ProRAWStreamTests.swift" "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz -framework Metal -o "$TEMP/test"
"$TEMP/test" "$@"
