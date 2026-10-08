#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCH" >&2; exit 1 ;; esac
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
APP="${RAWLAB_APP_PATH:-$ROOT/build/RawLab Mac.app}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
cmake -S "$ROOT/lutools" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DSONY2FUJI_ENABLE_GPU=ON -DSONY2FUJI_ENABLE_OPENMP=OFF -DBUILD_SHARED_LIB=OFF -DBUILD_TESTING=ON
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/LUTs" "$APP/Contents/Resources/FilmIcons" "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/lutools/third_party/Adobe-DNG-SDK-LICENSE.txt" "$APP/Contents/Resources/Licenses/"
cp -R "$ROOT/RawLabMac/Resources/Licenses/." "$APP/Contents/Resources/Licenses/"
cp "$ROOT/RawLabMac/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/Licenses/"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
# The CLT 27 SDK exposes SwiftUI macros without shipping their compiler plugin.
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
RAW_LIB="$(pkg-config --variable=libdir libraw)"
swiftc -swift-version 5 -O -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT"/RawLabMac/Sources/*.swift "$ROOT/Shared/ExportMetadata.swift" "$BUILD/libsony2fuji_core.a" \
    -L "$RAW_LIB" -lraw -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/RawLabMac"
cp "$ROOT/RawLabMac/Info.plist" "$APP/Contents/Info.plist"
bash "$ROOT/RawLabMac/build-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"
for lut in "$ROOT"/lutools/flog-2-new/*.cube; do
    case "$lut" in *FLog2-709*|*to_WDR*) continue ;; esac
    cp "$lut" "$APP/Contents/Resources/LUTs/"
done
for artwork in "$ROOT"/RawLabMac/Resources/FilmIcons/*; do
    case "$artwork" in
        *.png|*.jpg|*.jpeg) cp "$artwork" "$APP/Contents/Resources/FilmIcons/" ;;
    esac
done
# Package dependencies from either Homebrew or the architecture-specific source build.
# Refresh generated copies: existing files may belong to an older dependency build.
rm -f "$APP/Contents/Frameworks/"*.dylib
embed_dependency() {
    local binary="$1"
    local dependency source name
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*) continue ;;
            @rpath/*) source="$RAW_LIB/${dependency#@rpath/}" ;;
            /*) source="$dependency" ;;
            *) echo "Unsupported dependency path: $dependency" >&2; exit 1 ;;
        esac
        name="$(basename "$dependency")"
        if [ ! -f "$APP/Contents/Frameworks/$name" ]; then
            cp "$source" "$APP/Contents/Frameworks/$name"
            chmod u+w "$APP/Contents/Frameworks/$name"
            install_name_tool -id "@rpath/$name" "$APP/Contents/Frameworks/$name"
            embed_dependency "$APP/Contents/Frameworks/$name"
            codesign --force --sign - "$APP/Contents/Frameworks/$name"
        fi
        install_name_tool -change "$dependency" "@rpath/$name" "$binary"
    done < <(otool -L "$binary" | awk 'NR>1 {print $1}')
}
embed_dependency "$APP/Contents/MacOS/RawLabMac"
codesign --force --deep --sign - "$APP"
RAWLAB_ARCH="$ARCH" MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" bash "$ROOT/RawLabMac/tests/bundle.sh" "$APP"
echo "$APP"
