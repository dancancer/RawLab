#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
DEVICE="${1:?Pass an already booted dedicated simulator UDID (or 'auto')}"
if [ $# -ge 2 ]; then
    OUT="$2"
    OWN_OUT=0
else
    rawlab_ios_make_temp_dir OUT rawlab-camera-import-ft
    OWN_OUT=1
fi
cleanup() {
    if [ -n "${RESOLVED_DEVICE:-}" ]; then
        xcrun simctl uninstall "$RESOLVED_DEVICE" com.rawlab.tests.camera-import-fault-tolerance >/dev/null 2>&1 || true
    fi
    if [ "$OWN_OUT" = 1 ]; then
        rawlab_ios_cleanup_temp_dirs
    fi
}
trap cleanup EXIT

unset SDKROOT || true
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
PLAT="$(xcrun --sdk iphonesimulator --show-sdk-platform-path 2>/dev/null || true)"
if [[ -z "$SDK" || -z "$PLAT" ]] || ! command -v xcrun >/dev/null 2>&1; then
    if [[ "${RAWLAB_REQUIRE_SIMULATOR:-0}" == "1" ]]; then
        echo "FAIL: iPhoneSimulator SDK is unavailable and RAWLAB_REQUIRE_SIMULATOR=1" >&2
        exit 1
    fi
    echo "SKIP: iPhoneSimulator SDK unavailable for xcodebuild test-without-building"
    exit 0
fi

RESOLVED_DEVICE="$(python3 - "$DEVICE" <<'PY'
import json, subprocess, sys
requested = sys.argv[1]
try:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
    data = json.loads(raw)
except Exception:
    print("")
    sys.exit(0)
devices = []
for runtime, items in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for item in items:
        if item.get("isAvailable"):
            devices.append(item)
if not devices:
    print("NO_SIMULATORS")
    sys.exit(0)
if requested == "auto":
    booted = [d["udid"] for d in devices if d.get("state") == "Booted"]
    print(booted[0] if booted else devices[0]["udid"])
elif any(d["udid"] == requested for d in devices):
    print(requested)
else:
    print(f"MISSING:{requested}")
PY
)"

if [[ "$RESOLVED_DEVICE" == "NO_SIMULATORS" || -z "$RESOLVED_DEVICE" ]]; then
    if [[ "${RAWLAB_REQUIRE_SIMULATOR:-0}" == "1" ]]; then
        echo "FAIL: No available iOS Simulator device and RAWLAB_REQUIRE_SIMULATOR=1" >&2
        exit 1
    fi
    echo "SKIP: No available iOS Simulator for camera-import-fault-tolerance xcodebuild test-without-building"
    exit 0
fi

if [[ "$RESOLVED_DEVICE" == MISSING:* ]]; then
    echo "FAIL: Simulator UDID '${RESOLVED_DEVICE#MISSING:}' not found in available iOS simulators" >&2
    exit 1
fi

rawlab_ios_sim_init
mkdir -p "$OUT"

APP="$OUT/CameraImportFaultToleranceHost.app"
mkdir -p "$APP"
for lang in "$ROOT"/RawLab/RawLab/Resources/*.lproj; do
    cp -R "$lang" "$APP/"
done
cat > "$APP/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>CameraImportFaultToleranceHost</string>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.camera-import-fault-tolerance</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>CameraImportFaultToleranceHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST

rawlab_ios_sim_swiftc -parse-as-library -module-name CameraImportFaultToleranceHost \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/tests/CameraImportFaultToleranceHarness.swift" \
    -framework SwiftUI -framework UIKit \
    -o "$APP/CameraImportFaultToleranceHost"

BUNDLE="$APP/PlugIns/CameraImportFaultToleranceTests.xctest"
mkdir -p "$BUNDLE"
cat > "$BUNDLE/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>CameraImportFaultToleranceTests</string>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.camera-import-fault-tolerance-tests</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>CameraImportFaultToleranceTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

rawlab_ios_camera_sources CAMERA_SOURCES full
rawlab_ios_compile_sony_ptpip sim "$OUT/ptpip"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -DRAWLAB_XCTEST -module-name CameraImportFaultToleranceTests \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    -Xcc -I"$ROOT/lutools/include" \
    -parse-as-library -emit-library \
    -I "$PLAT/Developer/usr/lib" -I "$SDK/System/Library/Frameworks" \
    -F "$PLAT/Developer/Library/Frameworks" -F "$PLAT/Developer/Library/PrivateFrameworks" \
    -L "$PLAT/Developer/usr/lib" -framework XCTest \
    -lXCTestSwiftSupport -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/../../Frameworks \
    "${CAMERA_SOURCES[@]}" \
    "$ROOT/RawLab/tests/CameraSkipAndLimitTests.swift" \
    "$ROOT/RawLab/tests/CameraImportFaultToleranceXCTests.swift" \
    "$OUT/ptpip"/*.o -lc++ -o "$BUNDLE/CameraImportFaultToleranceTests"

mkdir -p "$APP/Frameworks"
for fw in XCTest.framework XCUIAutomation.framework Testing.framework _Testing_UIKit.framework _Testing_Foundation.framework _Testing_CoreGraphics.framework; do
    if [[ -d "$PLAT/Developer/Library/Frameworks/$fw" ]]; then
        cp -R "$PLAT/Developer/Library/Frameworks/$fw" "$APP/Frameworks/"
    fi
done
for fw in XCTestCore.framework XCTestSupport.framework XCTAutomationSupport.framework XCUnit.framework; do
    if [[ -d "$PLAT/Developer/Library/PrivateFrameworks/$fw" ]]; then
        cp -R "$PLAT/Developer/Library/PrivateFrameworks/$fw" "$APP/Frameworks/"
    fi
done
cp "$PLAT"/Developer/usr/lib/*.dylib "$APP/Frameworks/" || true
find "$APP/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -exec codesign --force --sign - {} + >/dev/null
codesign --force --sign - "$BUNDLE" >/dev/null
codesign --force --sign - "$APP" >/dev/null

cat > "$OUT/camera-import-fault-tolerance.xctestrun" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CameraImportFaultToleranceTests</key>
    <dict>
        <key>BundleIdentifiersForCrashReportEmphasis</key>
        <array><string>com.rawlab.tests.camera-import-fault-tolerance</string><string>com.rawlab.tests.camera-import-fault-tolerance-tests</string></array>
        <key>DependentProductPaths</key>
        <array><string>$APP</string><string>$BUNDLE</string></array>
        <key>IsAppHostedTestBundle</key><true/>
        <key>ProductModuleName</key><string>CameraImportFaultToleranceTests</string>
        <key>RunOrder</key><integer>0</integer>
        <key>SystemAttachmentLifetime</key><string>deleteOnSuccess</string>
        <key>TestBundlePath</key><string>$BUNDLE</string>
        <key>TestHostBundleIdentifier</key><string>com.rawlab.tests.camera-import-fault-tolerance</string>
        <key>TestHostPath</key><string>$APP</string>
        <key>TestingEnvironmentVariables</key>
        <dict>
            <key>DYLD_FRAMEWORK_PATH</key><string>$APP/Frameworks</string>
            <key>DYLD_INSERT_LIBRARIES</key><string>$APP/Frameworks/libXCTestBundleInject.dylib</string>
            <key>DYLD_LIBRARY_PATH</key><string>$APP/Frameworks</string>
        </dict>
    </dict>
</dict>
</plist>
PLIST

xcodebuild test-without-building \
    -xctestrun "$OUT/camera-import-fault-tolerance.xctestrun" \
    -destination "platform=iOS Simulator,id=$RESOLVED_DEVICE" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -derivedDataPath "$OUT/dd" \
    -resultBundlePath "$OUT/CameraImportFaultTolerance.xcresult"

xcrun xcresulttool get test-results summary --path "$OUT/CameraImportFaultTolerance.xcresult" --format json > "$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
if summary.get("passedTests", 0) < 8 or summary.get("failedTests", 1) != 0 or summary.get("skippedTests", 1) != 0:
    raise SystemExit(f"FAIL: unexpected xcresult summary: {summary}")
print(f"PASS: xcodebuild test-without-building passed {summary['passedTests']} XCTests on iOS Simulator")
PY
