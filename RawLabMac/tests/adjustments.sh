#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-adjustments.XXXXXX)"
SOURCES=("$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift")
if [ -f "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" ]; then
    SOURCES+=("$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift")
fi
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/RawLabMac/tests/AdjustmentTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/adjustments"
SAMPLES=()
if [ -n "${RAWLAB_TEST_RAW:-}" ]; then SAMPLES+=("$RAWLAB_TEST_RAW"); fi
for raw in "$ROOT"/lutools/examples/*; do
    case "$raw" in
        *.[Aa][Rr][Ww]|*.[Dd][Nn][Gg]|*.[Nn][Ee][Ff]|*.[Cc][Rr]2|*.[Cc][Rr]3|*.[Rr][Aa][Ff]|*.[Rr][Ww]2|*.[Oo][Rr][Ff]) SAMPLES+=("$raw") ;;
    esac
done
test "${#SAMPLES[@]}" -gt 0 || { echo 'Set RAWLAB_TEST_RAW to an external RAW path'; exit 1; }
for raw in "${SAMPLES[@]}"; do
    "$OUT/adjustments" "$ROOT" "$OUT/$(basename "$raw")" "$raw"
done
echo "PASS: ${#SAMPLES[@]} RAW fixtures; artifacts in $OUT"
