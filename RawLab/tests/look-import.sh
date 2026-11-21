#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
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
rawlab_ios_make_temp_dir OUT rawlab-ios-look-import
cleanup() {
    if [ "$OWNED_DEVICE" -eq 1 ] && [ -n "$DEVICE" ]; then
        xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
        xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
    fi
    rawlab_ios_cleanup_temp_dirs
}
trap cleanup EXIT

if [ -z "$DEVICE" ]; then
    SIMULATOR_PAIR="$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
items = json.load(sys.stdin).get("runtimes", [])
available = [item for item in items if item.get("platform") == "iOS" and item.get("isAvailable") and item.get("identifier")]
preferred = ("iPhone 16", "iPhone 15", "iPhone 14")
for runtime in sorted(available, key=lambda item: tuple(map(int, item["version"].split("."))), reverse=True):
    phones = {device["name"]: device["identifier"] for device in runtime.get("supportedDeviceTypes", [])
              if device.get("name", "").startswith("iPhone") and device.get("identifier")}
    if phones:
        name = next((name for name in preferred if name in phones), next(iter(phones)))
        print(runtime["identifier"], phones[name])
        break
else:
    sys.exit("No available iOS simulator runtime supports an iPhone device type")
')"
    read -r RUNTIME DEVICE_TYPE <<< "$SIMULATOR_PAIR"
    DEVICE="$(xcrun simctl create "RawLab Look Import $$" "$DEVICE_TYPE" "$RUNTIME")"
    OWNED_DEVICE=1
fi
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
HARNESS="$OUT/LookImportTests.app"
if [ -n "$APP" ]; then
    rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.look-import look-import "$APP"
else
    XCFRAMEWORK="${RAWLAB_IOS_XCFRAMEWORK:-$ROOT/lutools/build-ios/sony2fuji.xcframework}"
    SIMULATOR_FRAMEWORK="$(find "$XCFRAMEWORK" -path '*simulator*/sony2fuji.framework' -type d -print -quit)"
    [ -n "$SIMULATOR_FRAMEWORK" ] || {
        echo "No simulator sony2fuji.framework under $XCFRAMEWORK" >&2
        exit 1
    }
    rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.look-import look-import "$SIMULATOR_FRAMEWORK"
fi
SOURCES=(
    "$ROOT/Shared/DCPCompiler.swift"
    "$ROOT/Shared/LookLibrary.swift"
    "$ROOT/RawLab/RawLab/Core/Looks/LookImportCoordinator.swift"
    "$ROOT/RawLabMac/tests/DCPTestFixtures.swift"
    "$ROOT/RawLab/tests/LookImportTests.swift"
)
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/look-import"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/look-import"
