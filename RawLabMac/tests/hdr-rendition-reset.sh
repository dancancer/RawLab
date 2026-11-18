#!/bin/bash
# 不依赖辅助功能（AX）授权的 HDR 渲染重置按钮表示模型与真实布局契约测试（供 CI 模型套件执行）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/RawLabMac/build-env.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-rendition-reset.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="$(rawlab_mac_sdk_path)"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/Native/HDRCanvas.swift" "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLabMac/tests/HDRRenditionResetTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/test"
"$OUT/test"
