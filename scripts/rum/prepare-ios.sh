#!/bin/bash
# ============================================================================
#  准备 iOS 版阿里云 RUM SDK 2.4.2：官方 buildpack（固定 SHA-256）→ 编出封装层 xcframework，
#  并带上供应商预编译的核心 xcframework
#  用法：bash scripts/rum/prepare-ios.sh [输出目录]
#    不给目录时输出到共享缓存，并把 RawLab/Vendor/AlibabaCloudRUM 链到那里（Release 构建从这里链接）
# ============================================================================
set -euo pipefail
source "$(dirname "$0")/shared-cache.sh"
VERSION="2.4.2"
CACHE="$RUM_CACHE_ROOT/ios/$VERSION"
SOURCE="$CACHE/source"
OUT="${1:-$CACHE/build/release}"
LINK_VENDOR=$([[ $# -eq 0 ]] && echo 1 || echo 0)
# 默认输出时，让 Xcode 的 Release 构建从 RawLab/Vendor/AlibabaCloudRUM 找到 SDK
link_vendor() {
    [[ "$LINK_VENDOR" == 1 ]] || return 0
    mkdir -p "$RUM_REPO/RawLab/Vendor"
    ln -sfn "$OUT" "$RUM_REPO/RawLab/Vendor/AlibabaCloudRUM"
}
ARCHIVE="$CACHE/alibabacloud-rum-ios-buildpack-$VERSION.tar.gz"
ARCHIVE_SHA256="5faf1bb5ce880003273ab827676ab27bf53c691631e63be3f18282a0da3aa2b9"

mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --proto '=https' --max-time 180 --retry 2 \
        "https://github.com/aliyun/alibabacloud-rum-ios-buildpack/archive/refs/tags/$VERSION.tar.gz" \
        -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$ARCHIVE_SHA256" ]] || {
    echo "Unexpected iOS SDK archive SHA-256; refusing to build." >&2
    exit 2
}
if [[ ! -f "$SOURCE/VERSION" ]]; then
    rm -rf "$SOURCE" && mkdir -p "$SOURCE"
    tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"
fi

[[ "$(tr -d '[:space:]' < "$SOURCE/VERSION")" == "$VERSION" ]] || {
    echo "Unexpected cached iOS SDK version; refusing to build." >&2
    exit 2
}
[[ -f "$SOURCE/Sources/AlibabaCloudRUM/include/AlibabaCloudRUM.h" ]] || {
    echo "Cached AlibabaCloudRUM wrapper headers are missing." >&2
    exit 2
}
[[ -d "$SOURCE/Sources/AlibabaCloudRUMSDK/AlibabaCloudRUMSDK.xcframework" ]] || {
    echo "Cached AlibabaCloudRUMSDK.xcframework is missing." >&2
    exit 2
}

MARKER="$OUT/.prepared-version"
if [[ -f "$MARKER" && "$(tr -d '[:space:]' < "$MARKER")" == "$VERSION" ]]; then
    [[ -f "$OUT/AlibabaCloudRUM.xcframework/ios-arm64_x86_64-simulator/AlibabaCloudRUM.framework/AlibabaCloudRUM" ]] || {
        echo "Cached iOS RUM wrapper output is incomplete; remove it before retrying." >&2
        exit 2
    }
    printf 'PASS: reusing prepared AlibabaCloudRUM iOS %s output at %s\n' "$VERSION" "$OUT"
    link_vendor
    exit 0
fi
if [[ -e "$OUT" && -n "$(/usr/bin/find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "iOS RUM output directory is non-empty but has no valid preparation marker: $OUT" >&2
    exit 2
fi

mkdir -p "$OUT/wrapper/iphoneos" "$OUT/wrapper/iphonesimulator"

build_wrapper() {
    local sdk="$1"
    local platform="$2"
    local archs="$3"
    local build_root="$OUT/build/$platform"
    mkdir -p "$build_root"
    xcodebuild \
        -project "$SOURCE/AlibabaCloudRUM.xcodeproj" \
        -target AlibabaCloudRUM \
        -configuration Release \
        -sdk "$sdk" \
        ARCHS="$archs" \
        ONLY_ACTIVE_ARCH=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        IPHONEOS_DEPLOYMENT_TARGET=18.0 \
        SYMROOT="$build_root/symroot" \
        OBJROOT="$build_root/objroot" \
        CONFIGURATION_BUILD_DIR="$build_root/products"
    cp -R "$build_root/products/AlibabaCloudRUM.framework" "$OUT/wrapper/$platform/"
}

build_wrapper iphoneos iphoneos arm64
build_wrapper iphonesimulator iphonesimulator "arm64 x86_64"

xcodebuild -create-xcframework \
    -framework "$OUT/wrapper/iphoneos/AlibabaCloudRUM.framework" \
    -framework "$OUT/wrapper/iphonesimulator/AlibabaCloudRUM.framework" \
    -output "$OUT/AlibabaCloudRUM.xcframework"

cp -R "$SOURCE/Sources/AlibabaCloudRUMSDK/AlibabaCloudRUMSDK.xcframework" \
    "$OUT/AlibabaCloudRUMSDK.xcframework"
cp "$SOURCE/Sources/AlibabaCloudRUM/include/AlibabaCloudRUM.h" "$OUT/AlibabaCloudRUM.h"
printf '%s\n' "$VERSION" > "$MARKER"
link_vendor
printf 'PASS: prepared AlibabaCloudRUM iOS %s wrapper and cached core xcframework in %s\n' "$VERSION" "$OUT"
