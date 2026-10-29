#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_DEVICE_UDID:?Pass the explicitly authorized iPhone 14 Pro Max UDID}"
: "${RAWLAB_HDR_DEVICE_APP_ID:?Pass a private com.rawlab.tests.hdrui.* app ID}"
: "${RAWLAB_HDR_AUDIT_CLI:?Pass the current Mac CLI with HDR --info support}"
PRODUCTS="${1:?Pass signed device build-for-testing Build/Products}"
OUT="${2:?Pass a new task-owned output directory}"
JPEG="${3:?Pass a read-only 4080x3072 Android Ultra HDR original}"
HEIC="${4:?Pass a read-only oriented 3024x4032 iPhone HEIC original}"
mkdir -p "$OUT"
xcrun devicectl device info details --device "$IOS_DEVICE_UDID" --timeout 30 --quiet --json-output "$OUT/device.json"
python3 - "$PRODUCTS" "$OUT" "$JPEG" "$HEIC" <<'PY'
from pathlib import Path
import os,plistlib,json,shutil,subprocess,sys
products=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve()
device=os.environ['IOS_DEVICE_UDID'];app_id=os.environ['RAWLAB_HDR_DEVICE_APP_ID']
assert app_id.startswith('com.rawlab.tests.hdrui.'),'Use an isolated test app, never a daily-use bundle ID'
details=json.loads((out/'device.json').read_text())['result']
assert details['hardwareProperties']['productType']=='iPhone15,3','This fixture gate requires iPhone 14 Pro Max'
assert details['hardwareProperties']['reality']=='physical','A simulator does not satisfy this gate'
sources=list(products.glob('*.xctestrun'))
assert len(sources)==1,'Expected one device xctestrun'
def patch(v):
    if isinstance(v,str):return v.replace('__TESTROOT__',str(products))
    if isinstance(v,list):return [patch(x) for x in v]
    if isinstance(v,dict):return {k:patch(x) for k,x in v.items()}
    return v
value=patch(plistlib.loads(sources[0].read_bytes()))
targets=[t for c in value.get('TestConfigurations',[]) for t in c['TestTargets']]
if not targets:targets=[v for k,v in value.items() if not k.startswith('__') and isinstance(v,dict)]
target=next(t for t in targets if 'UITargetAppPath' in t)
original_app=Path(target['UITargetAppPath']);original_host=Path(target['TestHostPath'])
assert plistlib.loads((original_app/'Info.plist').read_bytes())['CFBundleIdentifier']==app_id
assert plistlib.loads((original_host/'Info.plist').read_bytes())['CFBundleIdentifier'].startswith('com.rawlab.tests.hdrui.')
app=out/'RawLabHDRUI.app';host=out/'RawLabHDRUITests-Runner.app'
for source,destination in [(original_app,app),(original_host,host)]:shutil.copytree(source,destination)
info_path=app/'Info.plist';info=plistlib.loads(info_path.read_bytes())
info.update(CFBundleDisplayName='RawLab HDR UI',CFBundleName='RawLab HDR UI',UIFileSharingEnabled=True,LSSupportsOpeningDocumentsInPlace=True)
info_path.write_bytes(plistlib.dumps(info))
info_path=host/'Info.plist';info=plistlib.loads(info_path.read_bytes())
info['NSPhotoLibraryUsageDescription']='Verify only photos created by the RawLab device UI tests.'
info_path.write_bytes(plistlib.dumps(info))
for bundle in [app,host]:
    subprocess.run(['codesign','--force','--deep','--preserve-metadata=entitlements','--sign',os.environ.get('RAWLAB_TEST_SIGN_IDENTITY','Apple Development'),str(bundle)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)
def relocate(v):
    if isinstance(v,str):return v.replace(str(original_app),str(app)).replace(str(original_host),str(host))
    if isinstance(v,list):return [relocate(x) for x in v]
    if isinstance(v,dict):return {k:relocate(x) for k,x in v.items()}
    return v
target.update(relocate(target))
target.setdefault('EnvironmentVariables',{})['RAWLAB_HDR_DEVICE_UI']='1'
tag=out.name
assert all(c.isalnum() or c in '-_' for c in tag),'Use a simple output directory name for unique fixture labels'
target['EnvironmentVariables']['RAWLAB_HDR_DEVICE_FIXTURE_TAG']=tag
plistlib.dump(value,(out/'hdr-device.xctestrun').open('wb'))
subprocess.run(['xcrun','devicectl','device','install','app','--device',device,str(app),'--timeout','60','--quiet','--json-output',str(out/'install.json')],check=True)
inputs=out/'inputs';inputs.mkdir()
for name in ['Android','iPhone']:
    lut=inputs/f'DeviceHDRCompatibility-{name}-{tag}.cube'
    lut.write_text(f'TITLE "DeviceHDRCompatibility-{name}-{tag}"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n')
fixtures=[(Path(sys.argv[3]),'RawLabHDRDevice-Android.jpg'),(Path(sys.argv[4]),'RawLabHDRDevice-iPhone.HEIC')]
fixtures += [(p,p.name) for p in inputs.glob('*.cube')]
for source,name in fixtures:
    subprocess.run(['xcrun','devicectl','device','copy','to','--device',device,'--source',str(source),'--destination','Documents/'+name,
        '--domain-type','appDataContainer','--domain-identifier',app_id,'--timeout','30','--quiet'],check=True)
PY
xcodebuild test-without-building -xctestrun "$OUT/hdr-device.xctestrun" \
    -destination "platform=iOS,id=$IOS_DEVICE_UDID" -destination-timeout 60 \
    -resultBundlePath "$OUT/HDRDeviceUI.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:RawLabUITests/HDRPhotoUITests/testDeviceJPEGCompatibilityAndPhotos \
    -only-testing:RawLabUITests/HDRPhotoUITests/testDeviceHEICCompatibilityAndPhotos > "$OUT/HDRDeviceUI.log" 2>&1
xcrun xcresulttool get test-results summary --path "$OUT/HDRDeviceUI.xcresult" --compact > "$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
assert (v['passedTests'],v['failedTests'],v['skippedTests'],v['totalTestCount'])==(2,0,0,2),v
assert v['expectedFailures']==0,v
PY
xcrun xcresulttool export attachments --path "$OUT/HDRDeviceUI.xcresult" --output-path "$OUT/attachments" > "$OUT/attachments.log"
python3 "$ROOT/RawLab/tests/verify-hdr-device-exports.py" --attachments "$OUT/attachments" --cli "$RAWLAB_HDR_AUDIT_CLI" --output "$OUT/photos-exports" > "$OUT/photos-audit.log"
python3 - "$OUT/summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
assert not any('Publishing changes from within view updates' in w['message'] for w in v['runtimeWarnings']),v['runtimeWarnings']
PY
echo "PASS executed physical HDR UI tests; Photos resource attachments: $OUT/HDRDeviceUI.xcresult"
