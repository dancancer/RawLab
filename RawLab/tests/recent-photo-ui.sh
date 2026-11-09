#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Use a fresh dedicated simulator with one test photo}"
PRODUCTS="${1:?Pass the current build-for-testing Build/Products directory}"
OUT="${2:?Pass a new output directory}"
test ! -e "$OUT"
mkdir -p "$OUT"
python3 - "$PRODUCTS" "$OUT" <<'PY'
from pathlib import Path
import os,plistlib,subprocess,sys
products,out=(Path(p).resolve() for p in sys.argv[1:])
runs=list(products.glob('*.xctestrun'))
assert len(runs)==1,'Expected one xctestrun'
def resolve(v):
 if isinstance(v,str):return v.replace('__TESTROOT__',str(products))
 if isinstance(v,list):return [resolve(x) for x in v]
 if isinstance(v,dict):return {k:resolve(x) for k,x in v.items()}
 return v
config=resolve(plistlib.loads(runs[0].read_bytes()))
targets=[t for c in config.get('TestConfigurations',[]) for t in c['TestTargets']]
if not targets:targets=[v for k,v in config.items() if not k.startswith('__') and isinstance(v,dict)]
for t in targets:
 t.setdefault('EnvironmentVariables',{})['RAWLAB_RECENT_UI']='1'
 if app:=t.get('UITargetAppPath'):
  bundle=plistlib.loads((Path(app)/'Info.plist').read_bytes())['CFBundleIdentifier']
  subprocess.run(['xcrun','simctl','install',os.environ['IOS_SIMULATOR_UDID'],app],check=True)
  subprocess.run(['xcrun','simctl','privacy',os.environ['IOS_SIMULATOR_UDID'],'grant','photos',bundle],check=True)
(out/'recent.xctestrun').write_bytes(plistlib.dumps(config))
PY
xcodebuild test-without-building -xctestrun "$OUT/recent.xctestrun" \
 -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
 -parallel-testing-enabled NO -only-testing:RawLabUITests/RecentPhotoUITests \
 -resultBundlePath "$OUT/RecentPhotoUITests.xcresult" > "$OUT/tests.log" 2>&1
xcrun xcresulttool get test-results summary --path "$OUT/RecentPhotoUITests.xcresult" --format json > "$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PYRESULT'
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary['passedTests']==1 and summary['skippedTests']==0 and summary['failedTests']==0,summary
PYRESULT
printf 'PASS: Recent photo persistence, filters, reopening and reset; %s\n' "$OUT"
