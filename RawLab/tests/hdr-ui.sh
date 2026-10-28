#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Pass the explicitly task-owned simulator UUID, seeded with one public HDR original}"
PRODUCTS="${1:?Pass build-for-testing Build/Products directory}"
OUT="${2:?Pass a new task-owned output directory}"
mkdir -p "$OUT"
python3 - "$PRODUCTS" "$OUT" <<'PY'
from pathlib import Path
import plistlib,sys
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
plistlib.dump(value,(out/'hdr.xctestrun').open('wb'))
PY
xcodebuild test-without-building -xctestrun "$OUT/hdr.xctestrun" \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -resultBundlePath "$OUT/HDRUI.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:"${RAWLAB_HDR_UI_TEST:-RawLabUITests/HDRPhotoUITests}" > "$OUT/HDRUI.log" 2>&1
echo "PASS executed HDR UI test; results: $OUT/HDRUI.xcresult"
