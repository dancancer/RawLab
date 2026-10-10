#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-effects-ui.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=()
for source in "$ROOT"/RawLabMac/Sources/*.swift; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/tests/PhotoEffectsPresentationTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/effects-ui"
"$OUT/effects-ui" "${1:?Pass a RAW fixture}" "${2:?Pass a screenshot directory}"
