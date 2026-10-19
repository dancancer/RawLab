#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
source "$ROOT/RawLabMac/build-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
APP="${RAWLAB_APP_PATH:-$ROOT/build/RawLab Mac.app}"
DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
# ----------------------------------------------------------------------------
#  使用统计 SDK：正式构建默认带上，上报正式环境；RAWLAB_RUM=0 显式出不带 SDK 的包
#  RAWLAB_RUM_LOCAL=1 是本地验证构建：环境变量配置、独立包名，产物只许放在 .cache/tmp/
# ----------------------------------------------------------------------------
RUM_FLAGS=(-swift-version 5)
RUM_LIB=""
if [ "${RAWLAB_RUM_LOCAL:-0}" = 1 ]; then
    if [ "${RAWLAB_RELEASE:-0}" = 1 ] || [ "${CONFIGURATION:-}" = Release ]; then
        echo "RUM local validation builds cannot be release builds." >&2; exit 2
    fi
    APP="$(swift -e 'import Foundation; print(URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath().path)' "$APP")"
    LOCAL_ROOT="$(cd "$ROOT" && pwd -P)/.cache/tmp"
    case "$APP" in
        "$LOCAL_ROOT/"*) ;;
        *) echo "RUM local app output must stay under .cache/tmp/." >&2; exit 2 ;;
    esac
    RUM_FLAGS+=(-D RAWLAB_RUM_LOCAL)
fi
if [ "${RAWLAB_RUM:-1}" = 1 ] || [ "${RAWLAB_RUM_LOCAL:-0}" = 1 ]; then
    RUM_BUILD="$BUILD/rum-sdk"
    bash "$ROOT/scripts/rum/prepare-macos.sh" "$RUM_BUILD"
    RUM_LIB="$RUM_BUILD/AlibabaCloud_RUM_macOS_0.4.4/lib/$ARCH/Release"
    RUM_FLAGS+=(-D RAWLAB_RUM -I "$RUM_BUILD/module" -L "$RUM_LIB" -lalibabacloud_rum)
fi
CHROMA_PREFIX="$RAWLAB_DEPENDENCY_PREFIX"
LENS_PREFIX="$RAWLAB_LENS_PREFIX"
if [ "${RAWLAB_CI_CACHE_HIT:-}" != true ]; then
    if ! pkg-config --exists rawlab-dng-sdk; then
        RAWLAB_ARCH="$ARCH" bash "$ROOT/RawLabMac/build-dependencies.sh"
    fi
    if [ ! -f "$CHROMA_PREFIX/lib/pkgconfig/opencv4.pc" ] || ! pkg-config --exact-version=4.12.0 opencv4; then
        RAWLAB_ARCH="$ARCH" bash "$ROOT/RawLabMac/build-chroma-dependency.sh"
    fi
    RAWLAB_ARCH="$ARCH" bash "$ROOT/RawLabMac/build-wavelet-dependency.sh"
    RAWLAB_ARCH="$ARCH" bash "$ROOT/RawLabMac/build-tiff-dependency.sh"
fi
RAWLAB_ARCH="$ARCH" MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" bash "$ROOT/RawLabMac/build-lens-dependency.sh"
pkg-config --exists 'libraw >= 0.22.2' 'rawlab-dng-sdk >= 1.7.1' 'opencv4 = 4.12.0' \
    'wavelib >= 1.0.0' 'lensfun >= 0.3.4' 'libtiff-4 >= 4.7.1'
cmake -S "$ROOT/lutools" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DSONY2FUJI_ENABLE_GPU=ON -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_LENSFUN=ON -DSONY2FUJI_ENABLE_DNGSDK=ON -DBUILD_SHARED_LIB=OFF -DBUILD_TESTING=ON
cmake --build "$BUILD" -j "${JOBS:-$(sysctl -n hw.ncpu)}"
"$BUILD/dng_jxl_tests"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/LUTs" "$APP/Contents/Resources/MasterRecipes" "$APP/Contents/Resources/MasterRecipeIcons" "$APP/Contents/Resources/FilmIcons" "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/RawLab-GPL-3.0.txt"
cp "$ROOT/LICENSE-ALIYUN-RUM-EXCEPTION" "$APP/Contents/Resources/Licenses/RawLab-Aliyun-RUM-Exception.txt"
cp "$ROOT/docs/reference/licensing.md" "$APP/Contents/Resources/Licenses/RawLab-Licensing.md"
cp "$ROOT/lutools/third_party/Adobe-DNG-SDK-LICENSE.txt" "$APP/Contents/Resources/Licenses/"
cp "$ROOT/lutools/third_party/nlohmann/LICENSE.MIT" "$APP/Contents/Resources/Licenses/nlohmann-JSON-MIT.txt"
cp -R "$ROOT/RawLabMac/Resources/Licenses/." "$APP/Contents/Resources/Licenses/"
cp "$ROOT/RawLabMac/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/Licenses/"
mkdir -p "$APP/Contents/Resources/Lensfun" "$APP/Contents/Resources/Licenses/Lensfun"
cp -R "$ROOT/lutools/third_party/lensfun/version_1/." "$APP/Contents/Resources/Lensfun/"
cp "$ROOT/lutools/third_party/lensfun/"*.txt "$ROOT/lutools/third_party/lensfun/"*.md "$APP/Contents/Resources/Licenses/Lensfun/"
cp -R "$LENS_PREFIX/licenses/lensfun/." "$APP/Contents/Resources/Licenses/Lensfun/"
OPENCV_PREFIX="$(pkg-config --variable=prefix opencv4)"
mkdir -p "$APP/Contents/Resources/Licenses/OpenCV"
cp -R "$OPENCV_PREFIX/share/licenses/opencv4/." "$APP/Contents/Resources/Licenses/OpenCV/"
cp "$CHROMA_PREFIX/share/licenses/wavelib/COPYRIGHT" "$APP/Contents/Resources/Licenses/wavelib-COPYRIGHT"
cp "$CHROMA_PREFIX/share/licenses/libtiff/LICENSE.md" "$APP/Contents/Resources/Licenses/libtiff-LICENSE.md"
mkdir -p "$APP/Contents/Resources/Licenses/dng-sdk"
cp "$CHROMA_PREFIX/share/licenses/rawlab-dng-sdk/"*.txt "$APP/Contents/Resources/Licenses/dng-sdk/"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
# The CLT 27 SDK exposes SwiftUI macros without shipping their compiler plugin.
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
RAW_LIB="$(pkg-config --variable=libdir libraw)"
APP_SOURCES=()
while IFS= read -r -d '' source; do APP_SOURCES+=("$source"); done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -O -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
    "${RUM_FLAGS[@]}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${APP_SOURCES[@]}" "$ROOT"/Shared/*.swift "$BUILD/libsony2fuji_core.a" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/RawLabMac"
cp "$ROOT/RawLabMac/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/master-recipes.json"
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
if [ "${RAWLAB_RUM_LOCAL:-0}" = 1 ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.rawlab.mac.rumlocal' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :RawLabRUMLocal bool true' "$APP/Contents/Info.plist"
fi
bash "$ROOT/RawLabMac/build-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"
for lut in "$ROOT"/lutools/flog-2-new/*.cube; do
    case "$lut" in *FLog2-709*|*to_WDR*) continue ;; esac
    cp "$lut" "$APP/Contents/Resources/LUTs/"
done
cp "$ROOT"/Shared/BundledLooks/*.cube "$APP/Contents/Resources/LUTs/"
cp "$ROOT/Shared/BundledLooks/catalog.json" "$APP/Contents/Resources/bundled-looks.json"
cp "$ROOT"/Shared/BundledLooks/Artwork/*.png "$APP/Contents/Resources/FilmIcons/"
cp "$ROOT/Shared/BundledLooks/NOTICE.md" "$APP/Contents/Resources/Licenses/Bundled-Looks.md"
if [ -d "$ROOT/RawLabMac/Resources/MasterRecipes" ]; then
    cp -R "$ROOT/RawLabMac/Resources/MasterRecipes/." "$APP/Contents/Resources/MasterRecipes/"
fi
cp "$ROOT"/RawLabMac/Resources/MasterRecipeIcons/*.png "$APP/Contents/Resources/MasterRecipeIcons/"
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
    local dependency source name rpath
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*) continue ;;
            @rpath/*)
                source="$RAW_LIB/${dependency#@rpath/}"
                if [ ! -f "$source" ]; then source="$OPENCV_PREFIX/lib/${dependency#@rpath/}"; fi
                if [ ! -f "$source" ]; then source="$LENS_PREFIX/lib/${dependency#@rpath/}"; fi
                if [ ! -f "$source" ] && [ -n "$RUM_LIB" ]; then source="$RUM_LIB/${dependency#@rpath/}"; fi
                ;;
            @loader_path/*)
                # 只有 RUM SDK 用相对路径引用它自带的 libcurl；嵌入后改写成 @rpath
                if [ -z "$RUM_LIB" ]; then echo "Unexpected loader-relative dependency" >&2; exit 1; fi
                source="$RUM_LIB/${dependency#@loader_path/}"
                ;;
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
    while IFS= read -r rpath; do
        case "$rpath" in
            /System/*|/usr/lib/*) ;;
            /*) install_name_tool -delete_rpath "$rpath" "$binary" ;;
        esac
    done < <(otool -l "$binary" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
        rpath && $1 == "path" {
            sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0
        }')
}
embed_dependency "$APP/Contents/MacOS/RawLabMac"
codesign --force --deep --sign - "$APP"
RAWLAB_RUM_EXPECTED="$([ -n "$RUM_LIB" ] && echo 1 || echo 0)" RAWLAB_ARCH="$ARCH" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" bash "$ROOT/RawLabMac/tests/bundle.sh" "$APP"
echo "$APP"
