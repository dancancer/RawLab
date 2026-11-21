#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
DEVICE="${1:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -n 1)}"
if [[ -z "$DEVICE" ]]; then
    echo "error: pass a booted iOS Simulator UDID or boot an iOS simulator" >&2
    exit 2
fi
rawlab_ios_make_temp_dir OUT rawlab-ios-wheel-layout
HARNESS="$OUT/NativeValueWheelLayoutTests.app"
mkdir -p "$HARNESS"
cat > "$HARNESS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.wheel-layout</string>
<key>CFBundleExecutable</key><string>wheel-layout</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Wheel Layout Tests</string>
<key>UISceneDelegateClassName</key><string>WheelLayoutTests.WheelLayoutSceneDelegate</string>
</dict></array></dict></dict>
</dict></plist>
PLIST
WHEEL_SOURCE="${RAWLAB_WHEEL_SOURCE:-$ROOT/RawLab/RawLab/UI/Adjustments/NativeValueWheel.swift}"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -module-name WheelLayoutTests \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentScale.swift" \
    "$WHEEL_SOURCE" \
    "$ROOT/RawLab/tests/NativeValueWheelLayoutTests.swift" \
    -o "$HARNESS/wheel-layout"
codesign --force --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
if [[ "${RAWLAB_WHEEL_SCREENSHOT_MODE:-}" == "1" ]]; then
    SIMCTL_CHILD_RAWLAB_WHEEL_SCREENSHOT_MODE=1 \
        xcrun simctl launch --terminate-running-process "$DEVICE" com.rawlab.tests.wheel-layout
    exit 0
fi
SIMCTL_CHILD_RAWLAB_WHEEL_RESULT="$OUT/result.json" \
    xcrun simctl launch --console --terminate-running-process "$DEVICE" com.rawlab.tests.wheel-layout
python3 - "$OUT/result.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    sys.exit("FAIL: NativeValueWheelLayoutTests did not produce result.json")
data = json.loads(path.read_text())
if not data.get("passed"):
    sys.exit(f"FAIL: NativeValueWheelLayoutTests reported failure ({len(data.get('failures', []))}/{data.get('checks')} failed)")
print(f"VERIFIED: {data['checks']} NativeValueWheel layout checks passed")
PY
