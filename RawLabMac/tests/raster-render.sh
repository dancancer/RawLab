#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
INPUT="${1:?Pass a real RAW fixture}"
CLI="${2:?Pass the sony2fuji CLI executable}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-raster-render.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" \
    "$ROOT/Shared/BundledLook.swift" \
  -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/RawLabMac/Sources/AgentRecipe.swift" \
  "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/Sources/Adjustments.swift" \
  "$ROOT/RawLabMac/Sources/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" \
  "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
  "$ROOT/RawLabMac/Sources/EditPersistence.swift" "$ROOT/RawLabMac/Sources/BatchExport.swift" \
  "$ROOT/RawLabMac/tests/RasterRenderTests.swift" \
  "${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/libsony2fuji_core.a" \
  -L "$(pkg-config --variable=libdir libraw)" \
  -lraw $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
  -o "$OUT/raster-render"

RAWLAB_TEST_ROOT="$ROOT" "$OUT/raster-render" "$INPUT" "$CLI"
