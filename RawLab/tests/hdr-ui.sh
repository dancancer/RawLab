#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Pass the explicitly task-owned simulator UUID, seeded with one public HDR original}"
PRODUCTS="${1:?Pass build-for-testing Build/Products directory}"
OUT="${2:?Pass a new task-owned output directory}"
mkdir -p "$OUT"
python3 - "$PRODUCTS" "$OUT" <<'PY'
from pathlib import Path
import os,plistlib,shutil,subprocess,sys
products=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve()
sources=list(products.glob('*.xctestrun'))
if len(sources)!=1:raise SystemExit('Expected one RawLab xctestrun')
value=plistlib.loads(sources[0].read_bytes())
def patch(v):
    if isinstance(v,str):return v.replace('__TESTROOT__',str(products))
    if isinstance(v,list):return [patch(x) for x in v]
    if isinstance(v,dict):return {k:patch(x) for k,x in v.items()}
    return v
value=patch(value)
targets=[t for c in value.get('TestConfigurations',[]) for t in c['TestTargets']]
if not targets:
    targets=[v for k,v in value.items() if not k.startswith('__') and isinstance(v,dict)]
for target in targets:
    target.setdefault('EnvironmentVariables',{})['RAWLAB_HDR_UI']='1'
    if 'UITargetAppPath' not in target:continue
    # 仅测试副本开启文件共享，使真实 Files picker 能访问本地 CUBE；不修改产品源码或构建产物。
    app=out/'RawLabHDRUI.app';original_app=target['UITargetAppPath']
    shutil.copytree(original_app,app)
    info_path=app/'Info.plist';info=plistlib.loads(info_path.read_bytes())
    info['UIFileSharingEnabled']=True;info['LSSupportsOpeningDocumentsInPlace']=True
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
    device=os.environ['IOS_SIMULATOR_UDID']
    subprocess.run(['xcrun','simctl','install',device,str(app)],check=True)
    data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,info['CFBundleIdentifier'],'data'],text=True).strip())
    documents=data/'Documents';documents.mkdir(exist_ok=True)
    fixture=documents/'HDRCompatibilityUnknown.cube'
    fixture.write_text('TITLE "HDRCompatibilityUnknown"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n')
    target['UITargetAppPath']=str(app)
    target['DependentProductPaths']=[str(app) if p==original_app else p for p in target.get('DependentProductPaths',[])]
plistlib.dump(value,(out/'hdr.xctestrun').open('wb'))
PY
xcodebuild test-without-building -xctestrun "$OUT/hdr.xctestrun" \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -resultBundlePath "$OUT/HDRUI.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:"${RAWLAB_HDR_UI_TEST:-RawLabUITests/HDRPhotoUITests}" > "$OUT/HDRUI.log" 2>&1
echo "PASS executed HDR UI test; results: $OUT/HDRUI.xcresult"
