#!/bin/bash
# ============================================================================
#  Xcode 构建阶段：带统计的构建（编译条件含 RAWLAB_RUM）把 RUM 核心动态库嵌入应用并签名
#  调试构建不带 SDK，直接跳过；SDK 缺失时报错并说明怎么准备
#  由 RawLab.xcodeproj 调用，依赖 Xcode 注入的构建变量
# ============================================================================
set -euo pipefail
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
    *" RAWLAB_RUM "*) ;;
    *) exit 0 ;;
esac
framework="$RAWLAB_RUM_SDK_DIR/AlibabaCloudRUMSDK.xcframework/$RAWLAB_RUM_SLICE/AlibabaCloudRUMSDK.framework"
if [[ ! -d "$framework" || ! -d "$RAWLAB_RUM_SDK_DIR/AlibabaCloudRUM.xcframework/$RAWLAB_RUM_SLICE" ]]; then
    echo "error: Alibaba Cloud RUM SDK not found in $RAWLAB_RUM_SDK_DIR; run scripts/rum/prepare-ios.sh first" >&2
    exit 1
fi
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination"
rm -rf "$destination/AlibabaCloudRUMSDK.framework"
cp -R "$framework" "$destination/"
# 供应商 2.4.2 的 plist 错写为 iOS 100.0；只修正嵌入副本，不改共享缓存。
# 模拟器的两个架构最低版本不同，取二进制中要求的较高版本。
embedded="$destination/AlibabaCloudRUMSDK.framework"
minimum_os="$(xcrun vtool -show-build "$embedded/AlibabaCloudRUMSDK" \
    | awk '$1 == "minos" {print $2}' \
    | sort -t . -k1,1n -k2,2n -k3,3n | tail -n 1)"
if [[ ! "$minimum_os" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: Cannot determine AlibabaCloudRUMSDK minimum iOS version" >&2
    exit 1
fi
/usr/bin/plutil -replace MinimumOSVersion -string "$minimum_os" "$embedded/Info.plist"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
        "$destination/AlibabaCloudRUMSDK.framework"
fi
