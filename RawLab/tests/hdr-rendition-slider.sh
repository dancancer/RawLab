#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass an already booted dedicated simulator UDID}"
OUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-rendition-slider.XXXXXX")}"
OWN_OUT=0
if [ $# -lt 2 ]; then
    OWN_OUT=1
fi
cleanup() {
    xcrun simctl uninstall "$DEVICE" com.rawlab.tests.hdr-rendition-slider >/dev/null 2>&1 || true
    xcrun simctl uninstall "$DEVICE" com.rawlab.tests.hdr-rendition-slider-uitests.xctrunner >/dev/null 2>&1 || true
    if [ "$OWN_OUT" = 1 ]; then
        rm -rf "$OUT"
    fi
}
trap cleanup EXIT

unset SDKROOT || true
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLAT="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios17.0-simulator"
mkdir -p "$OUT"

APP="$OUT/HDRRenditionSliderHarness.app"
mkdir -p "$APP"
for lang in "$ROOT"/RawLab/RawLab/Resources/*.lproj; do
    cp -R "$lang" "$APP/"
done
cat > "$APP/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>HDRRenditionSliderHarness</string>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.hdr-rendition-slider</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>HDRRenditionSliderHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>HDRRenditionSliderHarness</string>
<key>UISceneDelegateClassName</key><string>HDRRenditionSliderHarness.HDRRenditionSliderSceneDelegate</string>
</dict></array></dict></dict>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST

swiftc -swift-version 5 -parse-as-library -module-name HDRRenditionSliderHarness \
    -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" \
    "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/ColorGradingSettings.swift" \
    "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" \
    "$ROOT/Shared/HDRAdjustmentTransfer.swift" \
    "$ROOT/Shared/HDRDisplay.swift" \
    "$ROOT/Shared/Native/HDRCanvas.swift" \
    "$ROOT/Shared/Native/HDRMonitoring.swift" \
    "$ROOT/RawLab/tests/HDRRenditionSliderHarness.swift" \
    -framework SwiftUI -framework UIKit -framework MetalKit -framework UniformTypeIdentifiers \
    -o "$APP/HDRRenditionSliderHarness"
codesign --force --sign - "$APP" >/dev/null

# Stage 1: Method-level UIKit/Accessibility checks (VoiceOver .adjustable, non-touch .valueChanged, .disabled, panel disappear)
xcrun simctl install "$DEVICE" "$APP"
RESULT_JSON="$OUT/probe-result.json"
rm -f "$RESULT_JSON"
SIMCTL_CHILD_RAWLAB_SLIDER_RESULT="$RESULT_JSON" \
    xcrun simctl launch --console --terminate-running-process "$DEVICE" com.rawlab.tests.hdr-rendition-slider
python3 - "$RESULT_JSON" << 'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit("FAIL: HDRRenditionSliderHarness method probe did not produce result JSON")
data = json.loads(path.read_text())
failures = data.get("failures", [])
if failures or data.get("exitCode", 1) != 0:
    raise SystemExit("FAIL: HDRRenditionSliderHarness method probe failed:\n" + "\n".join(failures))
print(f"PASS: HDRRenditionSliderHarness method probe ({len(data.get('passes', []))} assertions)")
PY

if [[ "${RAWLAB_SLIDER_METHOD_ONLY:-0}" == 1 ]]; then
    exit 0
fi

# Stage 2: Real XCUITest touch/drag/micro-slide/double-tap/VoiceOver verification
RUNNER="$OUT/HDRRenditionSliderUITests-Runner.app"
cp -R "$PLAT/Developer/Library/Xcode/Agents/XCTRunner.app" "$RUNNER"
mv "$RUNNER/XCTRunner" "$RUNNER/HDRRenditionSliderUITests-Runner"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable HDRRenditionSliderUITests-Runner" \
    -c "Set :CFBundleIdentifier com.rawlab.tests.hdr-rendition-slider-uitests.xctrunner" \
    -c "Set :CFBundleName HDRRenditionSliderUITests-Runner" "$RUNNER/Info.plist"

BUNDLE="$RUNNER/PlugIns/HDRRenditionSliderUITests.xctest"
mkdir -p "$BUNDLE"
cat > "$BUNDLE/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>HDRRenditionSliderUITests</string>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.hdr-rendition-slider-uitests</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>HDRRenditionSliderUITests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSPrincipalClass</key><string>XCTestCase</string>
</dict></plist>
PLIST

swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" \
    -parse-as-library -emit-library \
    -I "$PLAT/Developer/usr/lib" -I "$SDK/System/Library/Frameworks" \
    -F "$PLAT/Developer/Library/Frameworks" -F "$PLAT/Developer/Library/PrivateFrameworks" \
    -L "$PLAT/Developer/usr/lib" -framework XCTest \
    -framework XCUIAutomation \
    -import-objc-header "$ROOT/RawLab/tests/HDRRenditionSliderSyntheticEvents.h" \
    -lXCTestSwiftSupport -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/Frameworks \
    "$ROOT/RawLab/tests/HDRRenditionSliderUITests.swift" -o "$BUNDLE/HDRRenditionSliderUITests"
mkdir -p "$RUNNER/Frameworks"
for fw in XCTest.framework XCUIAutomation.framework Testing.framework _Testing_UIKit.framework _Testing_Foundation.framework _Testing_CoreGraphics.framework; do
    cp -R "$PLAT/Developer/Library/Frameworks/$fw" "$RUNNER/Frameworks/"
done
for fw in XCTestCore.framework XCTestSupport.framework XCTAutomationSupport.framework XCUnit.framework; do
    cp -R "$PLAT/Developer/Library/PrivateFrameworks/$fw" "$RUNNER/Frameworks/"
done
cp "$PLAT"/Developer/usr/lib/*.dylib "$RUNNER/Frameworks/" || true
find "$RUNNER/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -exec codesign --force --sign - {} + >/dev/null
codesign --force --sign - "$BUNDLE" >/dev/null
codesign --force --sign - "$RUNNER" >/dev/null

cat > "$OUT/slider.xctestrun" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>HDRRenditionSliderUITests</key>
    <dict>
        <key>BundleIdentifiersForCrashReportEmphasis</key>
        <array><string>com.rawlab.tests.hdr-rendition-slider</string><string>com.rawlab.tests.hdr-rendition-slider-uitests</string></array>
        <key>IsUITestBundle</key><true/>
        <key>ProductModuleName</key><string>HDRRenditionSliderUITests</string>
        <key>RunOrder</key><integer>0</integer>
        <key>SystemAttachmentLifetime</key><string>deleteOnSuccess</string>
        <key>TargetAppBundleIdentifier</key><string>com.rawlab.tests.hdr-rendition-slider</string>
        <key>UITargetAppPath</key><string>$APP</string>
        <key>TestBundlePath</key><string>$BUNDLE</string>
        <key>TestHostBundleIdentifier</key><string>com.rawlab.tests.hdr-rendition-slider-uitests.xctrunner</string>
        <key>TestHostPath</key><string>$RUNNER</string>
        <key>UITargetAppEnvironmentVariables</key><dict/>
    </dict>
</dict>
</plist>
PLIST

xcodebuild test-without-building \
    -xctestrun "$OUT/slider.xctestrun" \
    -destination "platform=iOS Simulator,id=$DEVICE" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -derivedDataPath "$OUT/dd" \
    -resultBundlePath "$OUT/HDRRenditionSlider.xcresult"
