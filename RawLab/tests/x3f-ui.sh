#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Pass a dedicated task-owned simulator with no saved RawLab edits}"
: "${RAWLAB_TEST_RAW:?Pass an external DP1S X3F fixture with 2.2 saved settings}"
PRODUCTS="${1:?Pass build-for-testing Build/Products directory}"
OUT="${2:?Pass a new output directory}"
if [[ -e "$OUT" ]]; then echo "Output already exists: $OUT" >&2; exit 1; fi
mkdir -p "$OUT"
python3 - "$PRODUCTS" "$OUT" <<'PY'
from pathlib import Path
import os,plistlib,shutil,subprocess,sys,struct,hashlib,json
products=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();fixture=Path(os.environ['RAWLAB_TEST_RAW'])
raw=fixture.read_bytes();assert raw[:4]==b'FOVb' and struct.unpack_from('<I',raw,4)[0]==0x20002
slot=raw[72:104].index(6)
modified=bytearray(raw);struct.pack_into('<f',modified,104+4*slot,1.0)
exposure_slot=raw[72:104].index(1)
lens_raw=bytearray(raw)
exposure=struct.unpack_from('<f',raw,104+4*exposure_slot)[0]
struct.pack_into('<f',lens_raw,104+4*exposure_slot,0.125 if exposure!=0.125 else 0.25)
sources=list(products.glob('*.xctestrun'));assert len(sources)==1
value=plistlib.loads(sources[0].read_bytes())
def patch(v):
    if isinstance(v,str):return v.replace('__TESTROOT__',str(products))
    if isinstance(v,list):return [patch(x) for x in v]
    if isinstance(v,dict):return {k:patch(x) for k,x in v.items()}
    return v
value=patch(value)
targets=[t for c in value.get('TestConfigurations',[]) for t in c['TestTargets']]
if not targets:targets=[v for k,v in value.items() if not k.startswith('__') and isinstance(v,dict)]
for target in targets:
    target.setdefault('EnvironmentVariables',{})['RAWLAB_X3F_UI']='1'
    target['EnvironmentVariables']['RAWLAB_X3F_UI_RUN_ID']=out.name
    if 'UITargetAppPath' not in target:continue
    original=target['UITargetAppPath'];app=out/'RawLabX3FUI.app';shutil.copytree(original,app)
    info_path=app/'Info.plist';info=plistlib.loads(info_path.read_bytes())
    info['UIFileSharingEnabled']=True;info['LSSupportsOpeningDocumentsInPlace']=True
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
    device=os.environ['IOS_SIMULATOR_UDID'];subprocess.run(['xcrun','simctl','install',device,str(app)],check=True)
    data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,info['CFBundleIdentifier'],'data'],text=True).strip())
    documents=data/'Documents';documents.mkdir(exist_ok=True)
    (documents/f'X3F-Normal-{out.name}.X3F').write_bytes(raw)
    (documents/f'X3F-Unsupported-{out.name}.X3F').write_bytes(modified)
    (documents/f'X3F-Lens-{out.name}.X3F').write_bytes(lens_raw)
    # 使用独立内容身份预置旧版编辑；镜头匹配本身不影响 normal 的 active-lens 拒绝条件。
    edits=data/'Library/Application Support/RawLab/Edits/edits.json'
    edits.parent.mkdir(parents=True,exist_ok=True)
    store=json.loads(edits.read_text()) if edits.exists() else {'version':1,'records':{}}
    store['records']['content:'+hashlib.sha256(lens_raw).hexdigest()]={
        'settings':{'x3fMode':'legacy','lensCorrection':{
            'distortion':True,'tca':True,'autoCrop':True,'mode':'automatic'}},'updatedAt':0}
    edits.write_text(json.dumps(store))
    target['UITargetAppPath']=str(app)
    target['DependentProductPaths']=[str(app) if p==original else p for p in target.get('DependentProductPaths',[])]
plistlib.dump(value,(out/'x3f.xctestrun').open('wb'))
(out/'fixture.json').write_text(json.dumps({'source_sha256':hashlib.sha256(raw).hexdigest(),
    'lens_fixture_sha256':hashlib.sha256(lens_raw).hexdigest(),'source_unchanged':fixture.read_bytes()==raw},indent=2))
PY
xcodebuild test-without-building -xctestrun "$OUT/x3f.xctestrun" \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -resultBundlePath "$OUT/X3FUI.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never -only-testing:RawLabUITests/X3fRenderingUITests > "$OUT/X3FUI.log" 2>&1
xcrun xcresulttool get test-results summary --path "$OUT/X3FUI.xcresult" --compact > "$OUT/summary.json"
