#!/bin/bash
# P2-01 (S1): 持久化编辑记录 golden fixture (Shared/fixtures/edit-records-v1.json) macOS 模型层测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
OUT="$(mktemp -d /tmp/rawlab-edit-records.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/tests/EditRecordFixtureTests.swift" \
    -framework Foundation -framework CryptoKit -framework UniformTypeIdentifiers -framework ImageIO -o "$OUT/test"
cd "$ROOT"
"$OUT/test"
