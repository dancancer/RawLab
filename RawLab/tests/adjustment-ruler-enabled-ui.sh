#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass an already booted dedicated simulator UDID}"
ORIGINAL="${2:?Pass an existing version-1 RawLab build-for-testing xctestrun}"
OUT="${3:?Pass a new output directory for this isolated test run}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
RAWLAB_RULER_BUILD_ONLY=1 bash "$ROOT/RawLab/tests/adjustment-ruler-enabled.sh" "$DEVICE" "$OUT/harness"
python3 - "$ORIGINAL" "$OUT" <<'PY'
import pathlib, plistlib, shutil, sys
original = pathlib.Path(sys.argv[1]).resolve(strict=True)
output = pathlib.Path(sys.argv[2])
configuration = plistlib.load(original.open('rb'))
def relocate(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(original.parent))
    if isinstance(value, dict):
        return {key: relocate(item) for key, item in value.items()}
    if isinstance(value, list):
        return [relocate(item) for item in value]
    return value
configuration = relocate(configuration)
target = configuration['RawLabUITests']
runner = output / 'RawLabUITests-Runner.app'
shutil.copytree(target['TestHostPath'], runner)
target['TestHostPath'] = str(runner)
target['TestBundlePath'] = str(runner / 'PlugIns/RawLabUITests.xctest')
target['UITargetAppPath'] = str(output / 'harness/AdjustmentRulerEnabledTests.app')
target['UITargetAppEnvironmentVariables']['RAWLAB_RULER_UI_MODE'] = '1'
target['DependentProductPaths'] = [target['UITargetAppPath'], str(runner), target['TestBundlePath']]
plistlib.dump(configuration, (output / 'ruler-enabled.xctestrun').open('wb'))
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
TEST_BUNDLE="$OUT/RawLabUITests-Runner.app/PlugIns/RawLabUITests.xctest"
xcrun --sdk iphonesimulator swiftc -emit-library -swift-version 5 -module-name RawLabUITests \
    -sdk "$SDK" -target "${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios18.0-simulator" \
    -module-cache-path "$OUT/module-cache" -F "$PLATFORM/Developer/Library/Frameworks" \
    -I "$PLATFORM/Developer/usr/lib" -L "$PLATFORM/Developer/usr/lib" -lXCTestSwiftSupport \
    -framework XCTest "$ROOT/RawLab/tests/AdjustmentRulerEnabledUITests.swift" \
    -o "$TEST_BUNDLE/RawLabUITests"
codesign --force --sign - "$TEST_BUNDLE" >/dev/null
codesign --force --sign - "$OUT/RawLabUITests-Runner.app" >/dev/null
xcodebuild -xctestrun "$OUT/ruler-enabled.xctestrun" \
    -destination "platform=iOS Simulator,id=$DEVICE" \
    -only-testing:RawLabUITests/AdjustmentRulerEnabledUITests \
    -parallel-testing-enabled NO -collect-test-diagnostics never \
    -resultBundlePath "$OUT/ruler-enabled-ui.xcresult" test-without-building
