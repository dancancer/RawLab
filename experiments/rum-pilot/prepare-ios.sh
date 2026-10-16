#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="2.4.2"
CACHE="$ROOT/.cache/shared/aliyun-rum/ios/$VERSION"
SOURCE="$CACHE/source"
OUT="${1:?Pass an isolated output directory}"
ARCHIVE="$CACHE/alibabacloud-rum-ios-buildpack-$VERSION.tar.gz"
ARCHIVE_SHA256="5faf1bb5ce880003273ab827676ab27bf53c691631e63be3f18282a0da3aa2b9"

[[ -f "$ARCHIVE" ]] || {
    echo "Pinned iOS SDK source archive is missing." >&2
    exit 2
}
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$ARCHIVE_SHA256" ]] || {
    echo "Unexpected iOS SDK archive SHA-256; refusing to build." >&2
    exit 2
}

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
printf 'PASS: prepared AlibabaCloudRUM iOS %s wrapper and cached core xcframework in %s\n' "$VERSION" "$OUT"
