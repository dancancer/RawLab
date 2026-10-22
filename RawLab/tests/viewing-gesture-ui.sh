#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Dedicated simulator UUID}"
OUT="${2:?New output directory}"
mkdir -p "$OUT/source"
OUT="$(cd "$OUT" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
APP="$OUT/ViewingGesture.app"
RUNNER="$OUT/ViewingUITests-Runner.app"
cp -R "$PLATFORM/Developer/Library/Xcode/Agents/XCTRunner.app" "$RUNNER"
mkdir -p "$APP" "$RUNNER/PlugIns/RawLabUITests.xctest"
python3 - "$ROOT" "$OUT" <<'PY'
import pathlib,plistlib,sys,shutil,os,subprocess
root,out=map(pathlib.Path,sys.argv[1:]);runner=out/'ViewingUITests-Runner.app';app=out/'ViewingGesture.app';test=runner/'PlugIns/RawLabUITests.xctest'
p=plistlib.load((runner/'Info.plist').open('rb'));p.update(CFBundleIdentifier='com.rawlab.tests.viewing-uitests.xctrunner',CFBundleName='ViewingUITests-Runner',CFBundleExecutable='XCTRunner');plistlib.dump(p,(runner/'Info.plist').open('wb'))
plistlib.dump({'CFBundleIdentifier':'com.rawlab.tests.viewing-gesture','CFBundleExecutable':'viewing-gesture','CFBundlePackageType':'APPL','CFBundleVersion':'1','MinimumOSVersion':'18.0','CFBundleSupportedPlatforms':['iPhoneSimulator'],'UIDeviceFamily':[1,2],'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']},(app/'Info.plist').open('wb'))
plistlib.dump({'CFBundleIdentifier':'com.rawlab.tests.viewing-uitests','CFBundleExecutable':'RawLabUITests','CFBundlePackageType':'BNDL','CFBundleVersion':'1'},(test/'Info.plist').open('wb'))
for lang in (root/'RawLab/RawLab/Resources').glob('*.lproj'):shutil.copytree(lang,app/lang.name)
config={'RawLabUITests':{'BlueprintName':'RawLabUITests','ProductModuleName':'RawLabUITests','TestHostBundleIdentifier':p['CFBundleIdentifier'],'TestHostPath':str(runner),'TestBundlePath':str(test),'UITargetAppPath':str(app),'IsUITestBundle':True,'IsXCTRunnerHostedTestBundle':True,'DependentProductPaths':[str(runner),str(test),str(app)],'TestingEnvironmentVariables':{'DYLD_FRAMEWORK_PATH':'__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks','DYLD_LIBRARY_PATH':'__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib'}},'__xctestrun_metadata__':{'FormatVersion':1}}
plistlib.dump(config,(out/'viewing.xctestrun').open('wb'))
for n in ['ZoomablePhoto','PhotoZoomGeometry']:
 name='RawLab/RawLab/UI/Preview/'+n+'.swift'
 text=subprocess.check_output(['git','show',os.environ['RAWLAB_VIEWING_BASELINE']+':'+name],cwd=root) if os.environ.get('RAWLAB_VIEWING_BASELINE') and n=='ZoomablePhoto' else (root/name).read_bytes()
 (out/'source'/ (n+'.swift')).write_bytes(text)
for name in ['Shared/Localization.swift','RawLab/tests/ViewingGestureHarness.swift','RawLab/tests/ViewingGestureUITests.swift']:
 (out/'source'/pathlib.Path(name).name).write_bytes((root/name).read_bytes())
import hashlib,json
sources={str(f.relative_to(out/'source')):hashlib.sha256(f.read_bytes()).hexdigest() for f in (out/'source').glob('*.swift')}
(out/'source-receipt.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'baseline':os.environ.get('RAWLAB_VIEWING_BASELINE'),'sourceSHA256':sources,'scope':'isolated UIKit canvas; actual XCTest touch input, not full ContentView'},indent=2)+'\n')
PY
FLAGS=(-D VIEWING_CURRENT)
if [[ -n "${RAWLAB_VIEWING_BASELINE:-}" ]]; then FLAGS=(-D VIEWING_BASELINE); fi
xcrun --sdk iphonesimulator swiftc -parse-as-library -module-name ViewingGesture -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-cache-path "$OUT/module-cache" "${FLAGS[@]}" "$OUT/source/Localization.swift" "$OUT/source/PhotoZoomGeometry.swift" "$OUT/source/ZoomablePhoto.swift" "$OUT/source/ViewingGestureHarness.swift" -o "$APP/viewing-gesture"
xcrun --sdk iphonesimulator swiftc -emit-library -module-name RawLabUITests -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-cache-path "$OUT/module-cache" -F "$PLATFORM/Developer/Library/Frameworks" -I "$PLATFORM/Developer/usr/lib" -L "$PLATFORM/Developer/usr/lib" -lXCTestSwiftSupport -framework XCTest "$OUT/source/ViewingGestureUITests.swift" -o "$RUNNER/PlugIns/RawLabUITests.xctest/RawLabUITests"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --force --deep --sign - "$RUNNER" >/dev/null
xcrun simctl install "$DEVICE" "$APP"
STATUS=0
xcodebuild -xctestrun "$OUT/viewing.xctestrun" -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO -only-testing:RawLabUITests/ViewingGestureUITests -collect-test-diagnostics never -resultBundlePath "$OUT/viewing.xcresult" test-without-building || STATUS=$?
python3 - "$OUT" "$DEVICE" "$STATUS" <<'PY_RECEIPT'
import hashlib,json,pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]);device,status=sys.argv[2:];app=out/'ViewingGesture.app/viewing-gesture';runner=out/'ViewingUITests-Runner.app/PlugIns/RawLabUITests.xctest/RawLabUITests'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
d={'device':device,'exitCode':int(status),'appBinarySHA256':sha(app),'testBinarySHA256':sha(runner),'sources':str(out/'source-receipt.json'),'input':'actual XCTest taps/double tap/press/drag/pinch','scope':'isolated UIKit; no processor or full editor','installedAppBinarySHA256':None}
try:
 installed=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,'com.rawlab.tests.viewing-gesture','app'],text=True).strip())/'viewing-gesture'
 d.update(installedAppBinaryPath=str(installed),installedAppBinarySHA256=sha(installed))
except subprocess.CalledProcessError:pass
(out/'run-receipt.json').write_text(json.dumps(d,indent=2)+'\n')
PY_RECEIPT
exit "$STATUS"
