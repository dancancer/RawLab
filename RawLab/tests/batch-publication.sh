#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass a dedicated simulator UDID}"
OUT="$(mktemp -d /tmp/rawlab-ios-publication.XXXXXX)"
BUNDLE_ID=com.rawlab.tests.batch-publication
HARNESS="$OUT/BatchPublicationTests.app"
trap 'xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true; rm -rf "$OUT"' EXIT
mkdir -p "$HARNESS"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BUNDLE_ID" \
    -c "Set CFBundleExecutable batch-publication" "$HARNESS/Info.plist"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
    rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared" -g '*.swift' | sort
)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" \
    "$ROOT/RawLab/tests/BatchPublicationTests.swift" "$OUT/bridge.o" \
    -F "$APP/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker "$APP/Frameworks" -o "$HARNESS/batch-publication"
codesign --force --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
xcrun simctl privacy "$DEVICE" revoke photos "$BUNDLE_ID"
xcrun simctl spawn "$DEVICE" "$HARNESS/batch-publication"
