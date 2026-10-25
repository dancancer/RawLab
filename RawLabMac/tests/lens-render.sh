#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DSC06251.ARW}}"
if [ ! -f "$RAW" ]; then echo "Real RAW fixture unavailable: $RAW" >&2; exit 1; fi
mkdir -p "$ROOT/build/mac-tests"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/tests/LensRenderTests.swift" \
    "${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) \
    -lc++ -lz -framework AppKit -framework ImageIO -framework Metal -o "$ROOT/build/mac-tests/lens-render"
"$ROOT/build/mac-tests/lens-render" "$RAW" "$ROOT/lutools/third_party/lensfun/version_1"
