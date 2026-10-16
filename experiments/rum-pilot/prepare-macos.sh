#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="$ROOT/.cache/shared/aliyun-rum/macos/0.4.4"
SHA=b837d135b16eb1ec087cfba8796be2425765cb39e16b161d663364135e59085e
mkdir -p "$CACHE"
if [ ! -f "$CACHE/sdk.zip" ]; then
    curl --fail --location --proto '=https' --max-time 90 \
        https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_macOS.zip \
        -o "$CACHE/sdk.zip.download"
    mv "$CACHE/sdk.zip.download" "$CACHE/sdk.zip"
fi
test "$(shasum -a 256 "$CACHE/sdk.zip" | awk '{print $1}')" = "$SHA"
OUT="${1:?Pass an isolated output directory}"
mkdir -p "$OUT"
unzip -oq "$CACHE/sdk.zip" 'AlibabaCloud_RUM_macOS_0.4.4/*' -d "$OUT"
MODULE="$OUT/module"
mkdir -p "$MODULE"
cp "$OUT/AlibabaCloud_RUM_macOS_0.4.4/include/alibabacloud_rum.h" "$MODULE/"
printf 'module RawLabRUMNative { header "alibabacloud_rum.h" export * }\n' > "$MODULE/module.modulemap"
