#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT/build-ios-libraw/0.22.2"
SOURCES="$BASE/sources"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
JOBS="${JOBS:-6}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
mkdir -p "$SOURCES" "$ROOT/build-ios"

fetch() {
    local archive="$1" checksum="$2" url="$3" directory="$4"
    if [ ! -f "$SOURCES/$archive" ]; then
        curl -fL --retry 2 "$url" -o "$SOURCES/$archive"
    fi
    printf '%s  %s\n' "$checksum" "$SOURCES/$archive" | shasum -a 256 -c -
    if [ ! -d "$SOURCES/$directory" ]; then tar -xf "$SOURCES/$archive" -C "$SOURCES"; fi
}

fetch LibRaw-0.22.2.tar.gz de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa \
    https://www.libraw.org/data/LibRaw-0.22.2.tar.gz LibRaw-0.22.2
fetch LibRaw-cmake-eb98e43.tar.gz 3cd218bf6d1254de86e27269541277fbfc5bae57a9002ce0b46fbe2a97088b43 \
    https://github.com/LibRaw/LibRaw-cmake/archive/eb98e4325aef2ce85d2eb031c2ff18640ca616d3.tar.gz LibRaw-cmake-eb98e4325aef2ce85d2eb031c2ff18640ca616d3
fetch opencv-4.12.0.tar.gz 44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d \
    https://github.com/opencv/opencv/archive/refs/tags/4.12.0.tar.gz opencv-4.12.0
fetch opencv_contrib-4.12.0.tar.gz 4197722b4c5ed42b476d42e29beb29a52b6b25c34ec7b4d589c3ae5145fee98e \
    https://github.com/opencv/opencv_contrib/archive/refs/tags/4.12.0.tar.gz opencv_contrib-4.12.0
fetch wavelib-7f61bf5.tar.gz 62247c314bc98d395b0558882b37254b653753f0e1635cd5bd9807b27c79f96e \
    https://github.com/rafat/wavelib/archive/7f61bf592f3c470b2a7d8199431fde821d7253ac.tar.gz wavelib-7f61bf592f3c470b2a7d8199431fde821d7253ac
cmake -DLIBRAW_SOURCE_DIR="$SOURCES/LibRaw-0.22.2" -P "$ROOT/cmake/patch-libraw.cmake"

for config in iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64; do
    sdk="${config%-*}"
    arch="${config##*-}"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    prefix="$BASE/install/$config"
    common=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot"
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
        -DZLIB_LIBRARY="$sysroot/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$sysroot/usr/include")
    cmake -S "$SOURCES/LibRaw-cmake-eb98e4325aef2ce85d2eb031c2ff18640ca616d3" \
        -B "$BASE/libraw-$config" "${common[@]}" \
        -DLIBRAW_PATH="$SOURCES/LibRaw-0.22.2" -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_OPENMP=OFF \
        -DENABLE_LCMS=OFF -DENABLE_JASPER=OFF -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON
    cmake --build "$BASE/libraw-$config" --target raw -j "$JOBS"
    # The upstream install target includes raw_r as well as raw.
    cmake --build "$BASE/libraw-$config" --target raw_r -j "$JOBS"
    cmake --install "$BASE/libraw-$config"
    # Apple ships zlib in the SDK without pkg-config metadata.
    zlib_version="$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$sysroot/usr/include/zlib.h")"
    test -n "$zlib_version"
    printf 'prefix=%s\nName: zlib\nDescription: iOS SDK zlib\nVersion: %s\nLibs: -lz\nCflags: -I${prefix}/usr/include\n' \
        "$sysroot" "$zlib_version" > "$prefix/lib/pkgconfig/zlib.pc"
    core="$BASE/core-$config"
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
        cmake -S "$ROOT" -B "$core" -GXcode "${common[@]}" \
        -DIOS=ON -DBUILD_SHARED_LIB=ON -DBUILD_CLI=OFF -DBUILD_TESTING=OFF \
        -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_GPU=ON \
        -DSONY2FUJI_ENABLE_WAVELET_DENOISE=ON -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON -DSONY2FUJI_BUILD_DENOISE_DEPS=ON \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_OPENCV_CONTRIB="$SOURCES/opencv_contrib-4.12.0" \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_OPENCV="$SOURCES/opencv-4.12.0" \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_WAVELIB="$SOURCES/wavelib-7f61bf592f3c470b2a7d8199431fde821d7253ac" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON \
        -DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE="$core/output"
    cmake --build "$core" --config Release --target sony2fuji -j "$JOBS"
    framework="$core/output/sony2fuji.framework"
    mkdir -p "$framework/Licenses"
    cp "$ROOT/../LICENSE" "$framework/Licenses/RawLab-GPL-3.0.txt"
    cp "$ROOT/../docs/licensing.md" "$framework/Licenses/RawLab-Licensing.md"
    for name in COPYRIGHT LICENSE.CDDL LICENSE.LGPL; do
        cp "$SOURCES/LibRaw-0.22.2/$name" "$framework/Licenses/LibRaw-$name"
    done
    cp "$ROOT/third_party/rawspeed-camera-calibration.inc" "$framework/Licenses/"
    cp "$ROOT/third_party/Adobe-DNG-SDK-LICENSE.txt" "$framework/Licenses/"
    cp "$ROOT/../RawLabMac/Resources/Licenses/stb-MIT-LICENSE.txt" "$framework/Licenses/"
    cp "$ROOT/platform/ios/ThirdPartyNotices.md" "$framework/Licenses/"
    cp "$core/licenses/OpenCV-LICENSE" "$core/licenses/wavelib-COPYRIGHT" "$framework/Licenses/"
done

stage="$(mktemp -d "$ROOT/build-ios/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$BASE/core-iphonesimulator-arm64/output/sony2fuji.framework" "$stage/sony2fuji.framework"
lipo -create \
    "$BASE/core-iphonesimulator-arm64/output/sony2fuji.framework/sony2fuji" \
    "$BASE/core-iphonesimulator-x86_64/output/sony2fuji.framework/sony2fuji" \
    -output "$stage/sony2fuji.framework/sony2fuji"
xcodebuild -create-xcframework \
    -framework "$BASE/core-iphoneos-arm64/output/sony2fuji.framework" \
    -framework "$stage/sony2fuji.framework" -output "$stage/sony2fuji.xcframework"
bash "$ROOT/platform/ios/verify-framework.sh" "$stage/sony2fuji.xcframework"
destination="$ROOT/build-ios/sony2fuji.xcframework"
if [ -d "$destination" ]; then
    backup="$(mktemp -d "$ROOT/build-ios/previous.XXXXXX")"
    mv "$destination" "$backup/sony2fuji.xcframework"
    echo "Previous framework retained: $backup/sony2fuji.xcframework"
fi
mv "$stage/sony2fuji.xcframework" "$destination"
echo "Built: $destination"
