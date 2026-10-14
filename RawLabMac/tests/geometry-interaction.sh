#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPENDENCY_PREFIX="${RAWLAB_DEPENDENCY_PREFIX:-$ROOT/build/macos15-deps/$(uname -m)/install}"
export PKG_CONFIG_PATH="$DEPENDENCY_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
LINK_PACKAGES=(libraw rawlab-dng-sdk libtiff-4)
for package in opencv4 wavelib lensfun; do
    if pkg-config --exists "$package"; then LINK_PACKAGES+=("$package"); fi
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="${RAWLAB_INTERACTION_OUTPUT:-$ROOT/build/mac-geometry-ux/native-interaction}"
APP="$OUT/GeometryInteraction.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>GeometryInteraction</string><key>CFBundleIdentifier</key><string>com.rawlab.geometry-native-interaction</string><key>CFBundleName</key><string>RawLab Geometry Native Interaction</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do cp -R "$localization" "$APP/Contents/Resources/"; done
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
SOURCES=()
for source in "$ROOT"/RawLabMac/Sources/*.swift; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/tests/GeometryInteractionTests.swift" \
    "$BUILD/libsony2fuji_core.a" $(pkg-config --libs "${LINK_PACKAGES[@]}") \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$APP/Contents/MacOS/GeometryInteraction"
if [ "${RAWLAB_INTERACTION_BUILD_ONLY:-0}" = 1 ]; then exit 0; fi
RAW="${RAWLAB_TEST_RAW:-$ROOT/lutools/tests/fixtures/linear-uncompressed.dng}"
MODE=confirm
for argument in "$@"; do if [ "$argument" = --probe ]; then MODE=probe; fi; done
for argument in "$@"; do if [ "$argument" = --layouts-only ]; then MODE=layouts; fi; done
rm -f "$OUT/result-$MODE.txt"
open -n -W "$APP" --args "$RAW" "$OUT" "$@"
cat "$OUT/native-events-$MODE.log"
test -f "$OUT/result-$MODE.txt" && rg -q '^PASS$' "$OUT/result-$MODE.txt"
