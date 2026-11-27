#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
libraw_env="$(python3 "$ROOT/cmake/libraw/manifest.py" --shell)"
eval "$libraw_env"
BASE="$ROOT/build-ios-libraw/$RAWLAB_LIBRAW_VERSION"
SOURCES="${RAWLAB_IOS_SOURCE_CACHE:-$BASE/sources}"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
JOBS="${JOBS:-6}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Forward optional cache overrides, for example a local extracted DNG SDK:
#
#   bash .../build-framework.sh \
#     -DFETCHCONTENT_SOURCE_DIR_RAWLAB_DNG_SOURCE=/path/to/dng_sdk_1_7_1
mkdir -p "$SOURCES" "$ROOT/build-ios"

fetch() {
    local archive="$1" checksum="$2" url="$3" directory="$4"
    if [ ! -f "$SOURCES/$archive" ]; then
        curl -fL --retry 2 "$url" -o "$SOURCES/$archive"
    fi
    printf '%s  %s\n' "$checksum" "$SOURCES/$archive" | shasum -a 256 -c -
    if [ ! -d "$SOURCES/$directory" ]; then tar -xf "$SOURCES/$archive" -C "$SOURCES"; fi
}

fetch "$RAWLAB_LIBRAW_ARCHIVE" "$RAWLAB_LIBRAW_SHA256" \
    "$RAWLAB_LIBRAW_URL" "$RAWLAB_LIBRAW_DIRECTORY"
fetch "$RAWLAB_LIBRAW_CMAKE_ARCHIVE" "$RAWLAB_LIBRAW_CMAKE_SHA256" \
    "$RAWLAB_LIBRAW_CMAKE_URL" "$RAWLAB_LIBRAW_CMAKE_DIRECTORY"
fetch opencv-4.12.0.tar.gz 44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d \
    https://github.com/opencv/opencv/archive/refs/tags/4.12.0.tar.gz opencv-4.12.0
fetch opencv_contrib-4.12.0.tar.gz 4197722b4c5ed42b476d42e29beb29a52b6b25c34ec7b4d589c3ae5145fee98e \
    https://github.com/opencv/opencv_contrib/archive/refs/tags/4.12.0.tar.gz opencv_contrib-4.12.0
fetch wavelib-7f61bf5.tar.gz 62247c314bc98d395b0558882b37254b653753f0e1635cd5bd9807b27c79f96e \
    https://github.com/rafat/wavelib/archive/7f61bf592f3c470b2a7d8199431fde821d7253ac.tar.gz wavelib-7f61bf592f3c470b2a7d8199431fde821d7253ac
cmake -DLIBRAW_SOURCE_DIR="$SOURCES/$RAWLAB_LIBRAW_DIRECTORY" -P "$ROOT/cmake/patch-libraw.cmake"

build_slice() {
    local config="$1"
    shift
    local sdk arch sysroot rust_target core framework name
    sdk="${config%-*}"
    arch="${config##*-}"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    case "$config" in
        iphoneos-arm64) rust_target=aarch64-apple-ios ;;
        iphonesimulator-arm64) rust_target=aarch64-apple-ios-sim ;;
        iphonesimulator-x86_64) rust_target=x86_64-apple-ios ;;
    esac
    common=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot"
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
        -DZLIB_LIBRARY="$sysroot/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$sysroot/usr/include"
        -DSONY2FUJI_BUILD_RAW_DEPS=ON
        -DLIBRAW_PATH="$SOURCES/$RAWLAB_LIBRAW_DIRECTORY"
        -DLIBRAW_CMAKE_SOURCE_DIR="$SOURCES/$RAWLAB_LIBRAW_CMAKE_DIRECTORY"
        -DBUILD_SHARED_LIBS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_OPENMP=OFF
        -DENABLE_LCMS=OFF -DENABLE_JASPER=OFF
        -DSONY2FUJI_ENABLE_DNGSDK=ON
        -DSONY2FUJI_LIBRAW_TARGET=raw_r
        -DSONY2FUJI_DNGSDK_TARGET=rawlab_dng_sdk)
    # LibRaw and the Adobe DNG SDK are built by the shared core wrapper so the
    # static decoder and its SDK support use the same target architecture.
    core="$BASE/core-$config"
    cmake -S "$ROOT" -B "$core" -GXcode "${common[@]}" "$@" \
        -DIOS=ON -DBUILD_SHARED_LIB=ON -DBUILD_CLI=OFF -DBUILD_TESTING=OFF \
        -DSONY2FUJI_ENABLE_X3F=ON -DRAWLAB_X3F_RUST_TARGET="$rust_target" \
        -DSONY2FUJI_ENABLE_LENSFUN=ON -DSONY2FUJI_BUILD_LENS_DEPS=ON \
        -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_GPU=ON \
        -DSONY2FUJI_BUILD_TIFF_DEPS=ON \
        -DSONY2FUJI_ENABLE_WAVELET_DENOISE=ON -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON -DSONY2FUJI_BUILD_DENOISE_DEPS=ON \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_OPENCV_CONTRIB="$SOURCES/opencv_contrib-4.12.0" \
        -DOPENCV_SKIP_LINK_NO_UNDEFINED=ON \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_OPENCV="$SOURCES/opencv-4.12.0" \
        -DFETCHCONTENT_SOURCE_DIR_RAWLAB_WAVELIB="$SOURCES/wavelib-7f61bf592f3c470b2a7d8199431fde821d7253ac" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON \
        -DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE="$core/output"
    cmake --build "$core" --config Release --target sony2fuji -j "$JOBS"
    framework="$core/output/sony2fuji.framework"
    mkdir -p "$framework/Licenses"
    cp "$ROOT/../LICENSE" "$framework/Licenses/RawLab-GPL-3.0.txt"
    cp "$ROOT/../LICENSE-ALIYUN-RUM-EXCEPTION" "$framework/Licenses/RawLab-Aliyun-RUM-Exception.txt"
    cp "$ROOT/../docs/reference/licensing.md" "$framework/Licenses/RawLab-Licensing.md"
    for name in "${RAWLAB_LIBRAW_LICENSE_FILES[@]}"; do
        cp "$SOURCES/$RAWLAB_LIBRAW_DIRECTORY/$name" "$framework/Licenses/LibRaw-$name"
    done
    cp "$ROOT/third_party/rawspeed-camera-calibration.inc" "$framework/Licenses/"
    cp "$ROOT/third_party/Adobe-DNG-SDK-LICENSE.txt" "$framework/Licenses/"
    cp "$ROOT/third_party/nlohmann/LICENSE.MIT" "$framework/Licenses/nlohmann-JSON-MIT.txt"
    cp "$ROOT/../RawLabMac/Resources/Licenses/libspng-LICENSE.txt" "$framework/Licenses/"
    cp "$ROOT/../RawLabMac/Resources/Licenses/LibRaw-X3F-BSD.txt" "$framework/Licenses/"
    cp "$core/x3f-licenses.txt" "$framework/Licenses/X3F-Dependencies.txt"
    mkdir -p "$framework/Licenses/x3f-rust"
    cp -R "$core/x3f-rust-licenses/." "$framework/Licenses/x3f-rust/"
    cp -R "$core/licenses/libjpeg-turbo" "$framework/Licenses/"
    cp -R "$core/licenses/libultrahdr" "$framework/Licenses/"
    mkdir -p "$framework/Headers"
    cp "$ROOT/include/sony2fuji/ffi/sony2fuji_c.h" "$ROOT/include/sony2fuji/ffi/sony2fuji_hdr.h" "$framework/Headers/"
    cp "$ROOT/platform/ios/ThirdPartyNotices.md" "$framework/Licenses/"
    mkdir -p "$framework/Licenses/nikon-he"
    cp "$ROOT/third_party/nikon_he/README.md" "$ROOT/third_party/nikon_he/LICENSE.LGPL-2.1" "$framework/Licenses/nikon-he/"
    cp "$core/licenses/OpenCV-LICENSE" "$core/licenses/wavelib-COPYRIGHT" "$framework/Licenses/"
    cp -R "$core/licenses/lensfun" "$framework/Licenses/"
    rm -rf "$framework/Lensfun"
    mkdir -p "$framework/Lensfun"
    cp -R "$ROOT/third_party/lensfun/version_1/." "$framework/Lensfun/"
    cp "$core/licenses/libtiff/LICENSE.md" "$framework/Licenses/libtiff-LICENSE.md"
    test -d "$core/licenses/dng-sdk"
    cp -R "$core/licenses/dng-sdk" "$framework/Licenses/"
}

SLICES=(iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64)
# Slices share only the verified sources above; each has its own build tree and Cargo target
# directory. CMake's Xcode configure is mostly serial try_compile latency (~8 min per slice),
# so RAWLAB_IOS_PARALLEL_SLICES=1 overlaps the slices; each slice still uses -j "$JOBS".
if [ "${RAWLAB_IOS_PARALLEL_SLICES:-0}" = 1 ]; then
    logs="$ROOT/build-ios/slice-logs"
    rm -rf "$logs"
    mkdir -p "$logs"
    pids=()
    for config in "${SLICES[@]}"; do
        build_slice "$config" "$@" > "$logs/$config.log" 2>&1 &
        pids+=("$!")
    done
    failed=()
    for i in "${!SLICES[@]}"; do
        rc=0
        wait "${pids[$i]}" || rc=$?
        printf '[slice] %s (exit %s)\n' "${SLICES[$i]}" "$rc"
        cat "$logs/${SLICES[$i]}.log"
        if [ "$rc" -ne 0 ]; then
            failed+=("${SLICES[$i]} (exit $rc)")
        fi
    done
    rm -rf "$logs"
    if [ "${#failed[@]}" -gt 0 ]; then
        for slice in "${failed[@]}"; do
            printf 'error: iOS framework slice %s failed\n' "$slice" >&2
        done
        exit 1
    fi
else
    for config in "${SLICES[@]}"; do
        build_slice "$config" "$@"
    done
fi

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
