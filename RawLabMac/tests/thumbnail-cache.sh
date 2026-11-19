#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
OUT="$(mktemp -d /tmp/rawlab-thumbnail-cache.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/HSLNative.swift" \
    "$ROOT/Shared/ToneControlsNative.swift" \
    "$ROOT/Shared/AtmosphereNative.swift" \
    "$ROOT/Shared/ColorGradingNative.swift" \
    "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowserState.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacEditedPhotoPreviews.swift" \
    "$ROOT/RawLabMac/Sources/Library/MacWorkspaceBrowser.swift" \
    "$ROOT/RawLabMac/tests/ThumbnailCacheTests.swift" \
    -framework SwiftUI -framework AppKit -framework ImageIO -o "$OUT/thumbnail-cache"
"$OUT/thumbnail-cache"
