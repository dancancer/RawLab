#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="0.4.4"
SHA256="b837d135b16eb1ec087cfba8796be2425765cb39e16b161d663364135e59085e"
CACHE="$ROOT/.cache/shared/aliyun-rum/macos/$VERSION"
MODE="${1:---check}"
if [ "$#" -gt 1 ] || [[ "$MODE" != --check && "$MODE" != --send && "$MODE" != --help ]]; then
    echo "Usage: bash experiments/rum-pilot/run.sh [--check|--send|--help]" >&2
    exit 2
fi
if [ "$MODE" = --send ]; then
    SYSTEM_PROXY="$(scutil --proxy)"
    if /usr/bin/grep -Eq '(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable) : 1' <<< "$SYSTEM_PROXY"; then
        echo "NOT SENT: system proxy is enabled. Use a verified mainland-direct network; VPN/TUN must also be checked manually." >&2
        exit 2
    fi
fi
if [ ! -f "$CACHE/sdk.zip" ]; then
    mkdir -p "$CACHE"
    curl --fail --location --proto '=https' --tlsv1.2 --max-time 90 \
        --output "$CACHE/sdk.zip.download" \
        https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_macOS.zip
    mv "$CACHE/sdk.zip.download" "$CACHE/sdk.zip"
fi
ACTUAL="$(shasum -a 256 "$CACHE/sdk.zip" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "SDK checksum changed; refusing to build or send. Review the new vendor archive first." >&2
    exit 2
fi
OUT="$(mktemp -d /tmp/rawlab-rum-probe.XXXXXX)"
cleanup() {
    local status=$?
    if ! rm -rf "$OUT"; then
        echo "CLEANUP FAILED: inspect temporary directory $OUT" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 每次从已校验的归档解包，避免复用被修改或不完整的动态库。
unzip -q "$CACHE/sdk.zip" 'AlibabaCloud_RUM_macOS_0.4.4/*' -d "$OUT"
SDK_DIR="$OUT/AlibabaCloud_RUM_macOS_$VERSION"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
APPLE_SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
LIB_DIR="$SDK_DIR/lib/$(uname -m)/Release"
swiftc -swift-version 5 -sdk "$APPLE_SDK" \
    -import-objc-header "$SDK_DIR/include/alibabacloud_rum.h" \
    "$ROOT/experiments/rum-pilot/PilotConfiguration.swift" \
    "$ROOT/experiments/rum-pilot/Probe.swift" \
    -L "$LIB_DIR" -lalibabacloud_rum -Xlinker -rpath -Xlinker "$LIB_DIR" -o "$OUT/probe"
RAWLAB_RUM_CACHE_DIRECTORY="$OUT/cache" "$OUT/probe" "$MODE"
