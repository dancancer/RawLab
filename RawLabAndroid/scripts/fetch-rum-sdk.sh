#!/usr/bin/env bash
# ============================================================================
#  下载阿里云 RUM Android SDK（版本与 SHA-256 见 rum-sdk.env）到主工作区共享缓存
#  来源是供应商公开 Maven 仓库；校验不符即失败，SDK 二进制不进 Git
#  用法：bash scripts/fetch-rum-sdk.sh    之后正式包构建（build-release.sh）从缓存取用
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/rum-sdk.env"
source "$HERE/../../scripts/rum/shared-cache.sh"
NAME="alibabacloud-android-rum-sdk-$RUM_ANDROID_VERSION.aar"
URL="https://maven.aliyun.com/repository/public/com/aliyun/rum/alibabacloud-android-rum-sdk/$RUM_ANDROID_VERSION/$NAME"
DEST="$RUM_CACHE_ROOT/android/$RUM_ANDROID_VERSION/$NAME"
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$DEST" && "$(sha256 "$DEST")" == "$RUM_ANDROID_SHA256" ]]; then
    printf 'PASS: reusing %s\n' "$DEST"
    exit 0
fi
mkdir -p "$(dirname "$DEST")"
curl --fail --location --proto '=https' --max-time 180 --retry 2 -o "$DEST.download" "$URL"
[[ "$(sha256 "$DEST.download")" == "$RUM_ANDROID_SHA256" ]] || {
    rm -f "$DEST.download"
    echo "Unexpected SHA-256 from $URL; refusing to cache it." >&2
    exit 2
}
mv "$DEST.download" "$DEST"
printf 'PASS: fetched %s\n' "$DEST"
