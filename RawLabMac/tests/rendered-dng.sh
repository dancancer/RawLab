#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
INPUT="${1:?Pass a real RAW fixture}"
OUTPUT="${2:?Pass an ignored validation output directory}"
LUT="${3:-$ROOT/lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BIN="$(mktemp -d /tmp/rawlab-rendered-dng.XXXXXX)"
trap 'rm -rf "$BIN"' EXIT
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments.swift" "$ROOT/RawLabMac/Sources/MasterRecipe.swift" \
  "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
  "$ROOT/RawLabMac/Sources/EditPersistence.swift" "$ROOT/RawLabMac/Sources/BatchExport.swift" \
  "$ROOT/RawLabMac/tests/RenderedDNGExportTests.swift" "${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/libsony2fuji_core.a" \
  $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$BIN/test"
"$BIN/test" "$INPUT" "$OUTPUT" "$LUT"
