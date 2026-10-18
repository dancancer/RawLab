#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-lens-draft-controls.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
RPATHS=()
for dependency in libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
    "$ROOT/RawLabMac/Sources/Lens/MacLensPresentation.swift" "$ROOT/RawLabMac/tests/MacLensDraftControlsTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework AppKit -framework ImageIO -framework Metal "${RPATHS[@]}" -o "$OUT/test"
"$OUT/test"
