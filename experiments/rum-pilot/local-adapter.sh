#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
if scutil --proxy | /usr/bin/grep -Eq '(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable) : 1'; then
    echo "Refusing validation with an enabled system proxy" >&2; exit 2
fi
for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    if [ -n "${!name:-}" ]; then echo "Refusing validation with a proxy environment variable" >&2; exit 2; fi
done
OUT="$(mktemp -d /tmp/rawlab-rum-local.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
bash "$ROOT/scripts/rum/prepare-macos.sh" "$OUT/sdk"
LIB="$OUT/sdk/AlibabaCloud_RUM_macOS_0.4.4/lib/$(uname -m)/Release"
rawlabkit_flags link "$OUT/swiftpm" macos 1
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -D RAWLAB_RUM -D RAWLAB_RUM_LOCAL -I "$OUT/sdk/module" \
    "$ROOT/RawLabMac/Sources/Telemetry/RUMPCConfiguration.swift" "$ROOT/RawLabMac/Sources/Telemetry/AliyunRUMTransport.swift" \
    "$ROOT/experiments/rum-pilot/LocalAdapterProbe.swift" -L "$LIB" -lalibabacloud_rum \
    -Xlinker -rpath -Xlinker "$LIB" -o "$OUT/probe"
RAWLAB_RUM_CACHE_PARENT="$OUT" "$OUT/probe"
