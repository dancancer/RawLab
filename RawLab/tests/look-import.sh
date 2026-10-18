#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=""
DEVICE=""
OWNED_DEVICE=0
if [ "$#" -ge 2 ]; then
    APP="$1"
    DEVICE="$2"
elif [ "$#" -eq 1 ]; then
    if [ -d "$1" ] && [[ "$1" == *.app ]]; then
        APP="$1"
    else
        DEVICE="$1"
    fi
fi
OUT="$(mktemp -d /tmp/rawlab-ios-look-import.XXXXXX)"
cleanup() {
    if [ "$OWNED_DEVICE" -eq 1 ] && [ -n "$DEVICE" ]; then
        xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
        xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

if [ -z "$DEVICE" ]; then
    DEVICE_TYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
items = json.load(sys.stdin).get("devicetypes", [])
preferred = ["iPhone 16", "iPhone 15", "iPhone 14"]
for name in preferred:
    match = next((item for item in items if item.get("name") == name and item.get("identifier")), None)
    if match:
        print(match["identifier"])
        break
else:
    match = next((item for item in items if item.get("name", "").startswith("iPhone") and item.get("identifier")), None)
    if match:
        print(match["identifier"])
')"
    RUNTIME="$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
items = json.load(sys.stdin).get("runtimes", [])
available = [item for item in items if item.get("platform") == "iOS" and item.get("isAvailable") and item.get("identifier")]
if available:
    print(sorted(available, key=lambda item: item.get("version", ""))[-1]["identifier"])
')"
    [ -n "$DEVICE_TYPE" ] || { echo "No available iPhone simulator device type" >&2; exit 1; }
    [ -n "$RUNTIME" ] || { echo "No available iOS simulator runtime" >&2; exit 1; }
    DEVICE="$(xcrun simctl create "RawLab Look Import $$" "$DEVICE_TYPE" "$RUNTIME")"
    OWNED_DEVICE=1
fi
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
HARNESS="$OUT/LookImportTests.app"
mkdir -p "$HARNESS/Frameworks"
if [ -n "$APP" ]; then
    cp "$APP/Info.plist" "$HARNESS/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.look-import' \
        -c 'Set CFBundleExecutable look-import' "$HARNESS/Info.plist"
    cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
else
    /usr/libexec/PlistBuddy \
        -c 'Add CFBundleIdentifier string com.rawlab.tests.look-import' \
        -c 'Add CFBundleExecutable string look-import' \
        -c 'Add CFBundlePackageType string APPL' \
        -c 'Add CFBundleVersion string 1' \
        -c 'Add CFBundleShortVersionString string 1.0' \
        -c 'Add MinimumOSVersion string 18.0' \
        "$HARNESS/Info.plist"
    XCFRAMEWORK="${RAWLAB_IOS_XCFRAMEWORK:-$ROOT/lutools/build-ios/sony2fuji.xcframework}"
    SIMULATOR_FRAMEWORK="$(find "$XCFRAMEWORK" -path '*simulator*/sony2fuji.framework' -type d -print -quit)"
    [ -n "$SIMULATOR_FRAMEWORK" ] || {
        echo "No simulator sony2fuji.framework under $XCFRAMEWORK" >&2
        exit 1
    }
    cp -R "$SIMULATOR_FRAMEWORK" "$HARNESS/Frameworks/"
fi
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="$(uname -m)-apple-ios18.0-simulator"
SOURCES=(
    "$ROOT/Shared/Localization.swift"
    "$ROOT/Shared/DCPCompiler.swift"
    "$ROOT/Shared/LookLibrary.swift"
    "$ROOT/RawLab/RawLab/Core/Looks/LookImportCoordinator.swift"
    "$ROOT/RawLabMac/tests/DCPTestFixtures.swift"
    "$ROOT/RawLab/tests/LookImportTests.swift"
)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/look-import"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/look-import"
