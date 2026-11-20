#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
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

rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_core_shared_sources SOURCES "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -module-name PickerCancelHarness -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/PickerCancelHarness.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/picker-cancel-harness"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
echo "Picker cancellation harness installed: $HARNESS"
