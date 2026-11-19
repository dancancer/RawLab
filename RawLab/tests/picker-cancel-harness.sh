#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
OUT="${3:?Pass a new output directory}"
if [[ -e "$OUT" ]]; then echo "Output directory already exists: $OUT" >&2; exit 1; fi
HARNESS="$OUT/PickerCancelHarness.app"
mkdir -p "$HARNESS"
cp -R "$APP/." "$HARNESS/"
ORIGINAL_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$HARNESS/Info.plist")"
rm -f "$HARNESS/$ORIGINAL_EXECUTABLE"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.picker-cancel' \
    -c 'Set CFBundleExecutable picker-cancel-harness' "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete UIApplicationSceneManifest' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Delete UILaunchStoryboardName' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c 'Add UIApplicationSceneManifest dict' \
    -c 'Add UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication array' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0 dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneConfigurationName string Picker Cancel Harness' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName string PickerCancelHarness.PickerCancelSceneDelegate' \
    "$HARNESS/Info.plist"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared" -g '*.swift' -g '!**/tests/**' -g '!**/RawLabKit/**' | sort)
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
xcrun --sdk iphonesimulator swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -module-name PickerCancelHarness -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/PickerCancelHarness.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/picker-cancel-harness"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
echo "Picker cancellation harness installed: $HARNESS"
