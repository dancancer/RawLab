#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-effects-render.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
  "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" "$ROOT/Shared/Native/ProcessingMigrationNative.swift" "${HDR_SWIFT_SOURCES[@]}" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" "$ROOT/RawLabMac/tests/PhotoEffectsRenderTests.swift" \
  "${CORE_LINK[@]}" $(pkg-config --libs libraw_r opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
  -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:?Pass a real RAW fixture}" "${2:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}" "${3:-none}"
