#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
RESOURCES="${1:?Pass the built iOS resource bundle or app resource directory}"
DEVICE="${2:?Pass an explicit booted simulator UDID}"
OUT="$(mktemp -d /tmp/rawlab-look-artwork.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
xcrun --sdk iphonesimulator swiftc -parse-as-library "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
     "$ROOT/RawLab/tests/BundledLookArtworkTests.swift" -o "$OUT/artwork"
xcrun simctl spawn "$DEVICE" "$OUT/artwork" "$RESOURCES"
