#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="${1:-$(mktemp -d /tmp/rawlab-single-preview-interaction.XXXXXX)}"
APP="$OUT/ComparisonInteraction.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/module-cache" "$OUT/fixtures"
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
RPATHS=()
for dependency in libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT/RawLabMac/tests/SinglePreviewInteractionApp.swift" \
    "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    "${RPATHS[@]}" -o "$APP/Contents/MacOS/ComparisonInteraction"
/usr/libexec/PlistBuddy -c Clear "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.rawlab.agent.single-preview-interaction' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string ComparisonInteraction' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string ComparisonInteraction' "$APP/Contents/Info.plist"
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
for resource in FilmIcons MasterRecipeIcons MasterRecipes; do
    mkdir -p "$APP/Contents/Resources/$resource"
    cp -R "$ROOT/RawLabMac/Resources/$resource/." "$APP/Contents/Resources/$resource/"
done
mkdir -p "$APP/Contents/Resources/LUTs"
for lut in "$ROOT"/lutools/flog-2-new/*.cube; do
    case "$lut" in *FLog2-709*|*to_WDR*) continue ;; esac
    cp "$lut" "$APP/Contents/Resources/LUTs/"
done
ln -sfn "$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG" "$OUT/fixtures/fixture.dng"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
