#!/bin/bash
# ============================================================================
#  准备 macOS 版阿里云 RUM PC SDK 0.4.4：下载（固定 SHA-256）、解包、生成 Swift 模块
#  用法：bash scripts/rum/prepare-macos.sh <输出目录>
#  用供应商带版本号的固定地址；内容一旦变化，校验失败即停止，不会悄悄换成别的版本
# ============================================================================
set -euo pipefail
source "$(dirname "$0")/shared-cache.sh"
CACHE="$RUM_CACHE_ROOT/macos/0.4.4"
SHA=b837d135b16eb1ec087cfba8796be2425765cb39e16b161d663364135e59085e
mkdir -p "$CACHE"
if [ ! -f "$CACHE/sdk.zip" ]; then
    curl --fail --location --proto '=https' --max-time 180 --retry 2 \
        https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_macOS_0.4.4.zip \
        -o "$CACHE/sdk.zip.download"
    mv "$CACHE/sdk.zip.download" "$CACHE/sdk.zip"
fi
test "$(shasum -a 256 "$CACHE/sdk.zip" | awk '{print $1}')" = "$SHA" || {
    echo "Unexpected macOS RUM SDK archive SHA-256; refusing to build." >&2; exit 2;
}
OUT="${1:?Pass an isolated output directory}"
mkdir -p "$OUT"
unzip -oq "$CACHE/sdk.zip" 'AlibabaCloud_RUM_macOS_0.4.4/*' -d "$OUT"
MODULE="$OUT/module"
mkdir -p "$MODULE"
cp "$OUT/AlibabaCloud_RUM_macOS_0.4.4/include/alibabacloud_rum.h" "$MODULE/"
printf 'module RawLabRUMNative { header "alibabacloud_rum.h" export * }\n' > "$MODULE/module.modulemap"
