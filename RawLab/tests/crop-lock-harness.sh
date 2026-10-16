#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
OUT="${3:-$(mktemp -d /tmp/rawlab-ios-crop-lock.XXXXXX)}"
HARNESS="$OUT/CropLockHarness.app"
mkdir -p "$HARNESS/Frameworks"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.crop-lock' \
    -c 'Set CFBundleExecutable crop-lock-harness' "$HARNESS/Info.plist"
# Register the standalone UIKit scene instead of RawLab's SwiftUI lifecycle.
/usr/libexec/PlistBuddy -c 'Delete UIApplicationSceneManifest' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Delete UILaunchStoryboardName' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c 'Add UIApplicationSceneManifest dict' \
    -c 'Add UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication array' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0 dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneConfigurationName string Crop Lock Harness' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName string CropLockHarness.CropLockSceneDelegate' \
    "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/Shared" -g '*.swift' -g '!**/tests/**')
xcrun --sdk iphonesimulator swiftc -swift-version 5 -module-name CropLockHarness -O -sdk "$SDK" -target "$TARGET" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/RawLab/UI/EditorState/EditorCropOverlay.swift" \
    "$ROOT/RawLab/tests/CropLockHarness.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/crop-lock-harness"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
echo "Harness installed: $HARNESS"
echo "Use crop-lock-ui.sh to opt in and run CropLockUITests on simulator $DEVICE."
