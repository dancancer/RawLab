#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPENDENCY_PREFIX="${RAWLAB_DEPENDENCY_PREFIX:-$ROOT/build/macos15-deps/$(uname -m)/install}"
export PKG_CONFIG_PATH="$ROOT/build/lensfun/$(uname -m)/install/lib/pkgconfig:$DEPENDENCY_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
LINK_PACKAGES=(libraw rawlab-dng-sdk libtiff-4)
for package in opencv4 wavelib lensfun; do
    if pkg-config --exists "$package"; then LINK_PACKAGES+=("$package"); fi
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="$(mktemp -d /tmp/rawlab-geometry-edit-session.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/tests/fixtures/linear-uncompressed.dng}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass a RAW path'; exit 1; }
SOURCES=()
for name in Engine Adjustments MasterRecipe EditPersistence BatchExport EditorModel LookLibrary RenderScheduling FileLibrary BatchExportModel ExportSizePicker; do
    SOURCES+=("$ROOT/RawLabMac/Sources/$name.swift")
done
for name in Localization GeometrySettings HSLSettings HSLNative ExportMetadata; do
    SOURCES+=("$ROOT/Shared/$name.swift")
done
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${RAWLAB_TEST_DEPLOYMENT_TARGET:-26.0}" \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/RawLabMac/tests/GeometryEditSessionTests.swift" \
    "$BUILD/libsony2fuji_core.a" $(pkg-config --libs "${LINK_PACKAGES[@]}") \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$RAW"
