#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Shared/tests/mac-native-sources.sh"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-effects-ui.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$MAC_NATIVE_BRIDGING_HEADER" \
    "${SOURCES[@]}" "${MAC_SHARED_SWIFT_SOURCES[@]}" "$ROOT/RawLabMac/tests/PhotoEffectsPresentationTests.swift" \
    "${CORE_LINK[@]}" \
    -L "$(pkg-config --variable=libdir libraw_r)" -lraw_r $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/effects-ui"
"$OUT/effects-ui" "${1:?Pass a RAW fixture}" "${2:?Pass a screenshot directory}"
