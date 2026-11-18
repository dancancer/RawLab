#!/bin/bash
# 各语言界面文字放得下：配方卡片说明、工具名等，按 SwiftUI 实际排版测量
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-text-fit.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "$OUT/ModuleCache" \
     "$ROOT/RawLabMac/Sources/Editor/View/AdjustmentPanelLayout.swift" \
    "$ROOT/RawLabMac/tests/TextFitTests.swift" -framework SwiftUI -framework AppKit -o "$OUT/text-fit"
"$OUT/text-fit" "$ROOT"
