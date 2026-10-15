#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass an already booted dedicated simulator UDID}"
OUT="${2:-$(mktemp -d /tmp/rawlab-ios-ruler-enabled.XXXXXX)}"
HARNESS="$OUT/AdjustmentRulerEnabledTests.app"
mkdir -p "$HARNESS"
cat > "$HARNESS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.ruler-enabled</string>
<key>CFBundleExecutable</key><string>ruler-enabled</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Ruler Enabled Tests</string>
<key>UISceneDelegateClassName</key><string>RulerEnabledTests.RulerEnabledSceneDelegate</string>
</dict></array></dict></dict>
</dict></plist>
PLIST
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios18.0-simulator"
RULER="${RAWLAB_RULER_SOURCE:-$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentRuler.swift}"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 -module-name RulerEnabledTests \
    -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentScale.swift" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/NativeValueWheel.swift" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentControl.swift" \
    "$RULER" "$ROOT/RawLab/tests/AdjustmentRulerEnabledHarness.swift" -o "$HARNESS/ruler-enabled"
codesign --force --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
if [[ "${RAWLAB_RULER_BUILD_ONLY:-}" == 1 ]]; then
    echo "Harness installed: $HARNESS"
    exit 0
fi
SIMCTL_CHILD_RAWLAB_RULER_RESULT="$OUT/result.json" \
    xcrun simctl launch --console --terminate-running-process "$DEVICE" com.rawlab.tests.ruler-enabled
echo "Method-level observations: $OUT/result.json"
