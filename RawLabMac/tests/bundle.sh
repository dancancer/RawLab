#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cmp "$ROOT/Shared/master-recipes.json" "${1:-$ROOT/build/RawLab Mac.app}/Contents/Resources/master-recipes.json"
APP="${1:-$ROOT/build/RawLab Mac.app}"
cmp "$ROOT/Shared/BundledLooks/catalog.json" "$APP/Contents/Resources/bundled-looks.json"
for asset in "$ROOT"/Shared/BundledLooks/*.cube; do
    cmp "$asset" "$APP/Contents/Resources/LUTs/$(basename "$asset")"
done
cmp "$ROOT/RawLabMac/Resources/FilmIcons/ektar-100-phuket.png" "$APP/Contents/Resources/FilmIcons/ektar-100-phuket.png"
for asset in "$ROOT"/Shared/BundledLooks/Artwork/*.png; do
    cmp "$asset" "$APP/Contents/Resources/FilmIcons/$(basename "$asset")"
done
cmp "$ROOT/Shared/BundledLooks/NOTICE.md" "$APP/Contents/Resources/Licenses/Bundled-Looks.md"
for language in en zh-Hans de fr ja es; do
    cmp "$ROOT/RawLabMac/Resources/$language.lproj/Localizable.strings" "$APP/Contents/Resources/$language.lproj/Localizable.strings"
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
for asset in "$ROOT"/RawLabMac/Resources/MasterRecipes/*.cube "$ROOT"/RawLabMac/Resources/MasterRecipeIcons/*.png; do
    directory=$(basename "$(dirname "$asset")")
    cmp "$asset" "$APP/Contents/Resources/$directory/$(basename "$asset")" || {
        echo "FAIL: missing or stale recipe asset $(basename "$asset")"; exit 1;
    }
done
for notice in RawLab-GPL-3.0.txt RawLab-Aliyun-RUM-Exception.txt RawLab-Licensing.md libtiff-LICENSE.md; do
    test -f "$APP/Contents/Resources/Licenses/$notice"
done
cmp "$ROOT/LICENSE-ALIYUN-RUM-EXCEPTION" "$APP/Contents/Resources/Licenses/RawLab-Aliyun-RUM-Exception.txt"
for notice in GLib-COPYING PCRE2-LICENCE proxy-libintl-COPYING zlib-LICENSE; do
    test -f "$APP/Contents/Resources/Licenses/Lensfun/$notice"
done
for notice in Adobe-DNG-SDK-LICENSE.txt JPEG-XL-LICENSE.txt Brotli-LICENSE.txt \
        Highway-LICENSE.txt Highway-LICENSE-BSD3.txt skcms-LICENSE.txt; do
    test -f "$APP/Contents/Resources/Licenses/dng-sdk/$notice"
done
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
    minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
    test "$minimum" = "$MACOSX_DEPLOYMENT_TARGET" || {
        echo "FAIL: app minimum macOS is $minimum, expected $MACOSX_DEPLOYMENT_TARGET"; exit 1;
    }
fi
for binary in "$APP/Contents/MacOS/RawLabMac" "$APP"/Contents/Frameworks/*.dylib; do
    if [ -n "${RAWLAB_ARCH:-}" ]; then
        test "$(lipo -archs "$binary")" = "$RAWLAB_ARCH" || {
            echo "FAIL: unexpected architecture in $binary"; exit 1;
        }
    fi
    if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
        # 新式 LC_BUILD_VERSION 写 minos；RUM SDK 的 x86_64 库只有旧式 LC_VERSION_MIN_MACOSX
        minimum=$(xcrun vtool -show-build "$binary" | awk '
            $1 == "cmd" { cmd = $2 }
            cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }
            cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }')
        awk -v actual="$minimum" -v target="$MACOSX_DEPLOYMENT_TARGET" 'BEGIN {
            if (actual == "") exit 1;
            split(actual, a, "."); split(target, t, ".");
            for (i = 1; i <= 3; i++) {
                if (a[i] + 0 < t[i] + 0) exit 0;
                if (a[i] + 0 > t[i] + 0) exit 1;
            }
        }' || { echo "FAIL: $binary requires macOS $minimum, expected <= $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*) ;;
            @rpath/*)
                test -f "$APP/Contents/Frameworks/${dependency#@rpath/}" || {
                    echo "FAIL: missing bundled dependency $dependency"; exit 1;
                }
                ;;
            *) echo "FAIL: external dependency $dependency in $binary"; exit 1 ;;
        esac
    done < <(otool -L "$binary" | awk 'NR>1 {print $1}')
    while IFS= read -r rpath; do
        case "$rpath" in
            /System/*|/usr/lib/*|@*) ;;
            /*) echo "FAIL: external runtime search path $rpath in $binary"; exit 1 ;;
        esac
    done < <(otool -l "$binary" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
        rpath && $1 == "path" {
            sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0
        }')
    codesign --verify --strict "$binary"
done
codesign --verify --deep --strict "$APP"
# 使用统计 SDK：带与不带必须和构建方式一致，不能悄悄缺失或混入
if [ -n "${RAWLAB_RUM_EXPECTED:-}" ]; then
    linked=0
    otool -L "$APP/Contents/MacOS/RawLabMac" | grep -q '@rpath/libalibabacloud_rum.dylib' && linked=1
    for lib in libalibabacloud_rum.dylib libcurl.dylib; do
        present=0; [ -f "$APP/Contents/Frameworks/$lib" ] && present=1
        test "$present" = "$RAWLAB_RUM_EXPECTED" || { echo "FAIL: $lib presence $present, expected $RAWLAB_RUM_EXPECTED"; exit 1; }
    done
    test "$linked" = "$RAWLAB_RUM_EXPECTED" || { echo "FAIL: RUM SDK link state $linked, expected $RAWLAB_RUM_EXPECTED"; exit 1; }
    test -f "$APP/Contents/Resources/Licenses/libcurl-COPYING.txt"
fi
echo 'PASS: all non-system dynamic dependencies are bundled and signed'
