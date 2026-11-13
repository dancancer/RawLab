#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Shared/tests/mac-native-sources.sh"
source "$ROOT/RawLabMac/tests/native-env.sh"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-ai-denoise.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    -import-objc-header "$MAC_NATIVE_BRIDGING_HEADER" \
    "${SOURCES[@]}" "${MAC_SHARED_SWIFT_SOURCES[@]}" "$ROOT/RawLabMac/tests/AIDenoiseTests.swift" "$ROOT/RawLabMac/tests/AIDenoiseRecoveryChecks.swift" \
    "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw_r rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$@"
