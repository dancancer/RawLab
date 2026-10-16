#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOURCES="${1:?Pass the built iOS resource bundle or app resource directory}"
DEVICE="${2:?Pass an explicit booted simulator UDID}"
OUT="$(mktemp -d /tmp/rawlab-look-artwork.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
    "$ROOT/Shared/BundledLook.swift" "$ROOT/RawLab/tests/BundledLookArtworkTests.swift" -o "$OUT/artwork"
xcrun simctl spawn "$DEVICE" "$OUT/artwork" "$RESOURCES"
