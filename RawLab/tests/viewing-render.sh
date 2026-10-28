#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Pass dedicated task simulator UUID}"
OUT="${2:?Pass new output directory}"
FRAMEWORK="${3:-$ROOT/lutools/build-ios/sony2fuji.xcframework/ios-arm64-simulator/sony2fuji.framework}"
mkdir -p "$OUT/ViewingRenderTests.app/Frameworks" "$OUT/source"
OUT="$(cd "$OUT" && pwd)"
APP="$OUT/ViewingRenderTests.app"
cp -R "$FRAMEWORK" "$APP/Frameworks/"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1]);plistlib.dump({'CFBundleIdentifier':'com.rawlab.tests.viewing-render','CFBundleExecutable':'viewing-render','CFBundlePackageType':'APPL','CFBundleVersion':'1','MinimumOSVersion':'18.0','CFBundleSupportedPlatforms':['iPhoneSimulator'],'UIDeviceFamily':[1,2]},(p/'Info.plist').open('wb'))
PY
python3 - "$ROOT" "$OUT" <<'PY_SOURCES'
import pathlib,shutil,sys,subprocess,json,hashlib
root,out=map(pathlib.Path,sys.argv[1:]);files=[]
for folder in ['RawLab/RawLab/Core','Shared']:
 files.extend(p for p in (root/folder).rglob('*.swift') if 'tests' not in p.relative_to(root).parts)
files.extend([root/'RawLab/tests/ViewingRenderTests.swift',root/'RawLab/RawLab/Support/RawMetadataBridge.mm',root/'RawLab/RawLab/Support/RawMetadataBridge.h',root/'RawLab/RawLab/Support/RawLab-Bridging-Header.h'])
for p in files:
 dest=out/'source'/p.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
(out/'source-receipt.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceSHA256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},'scope':'direct VM+actual native processor; no touch input'},indent=2)+'\n')
PY_SOURCES
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" -I "$ROOT/lutools/include" -c "$OUT/source/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$OUT/source/RawLab/RawLab/Core" "$OUT/source/Shared" -g '*.swift' -g '!**/tests/**' | sort)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" "$OUT/source/RawLab/tests/ViewingRenderTests.swift" "$OUT/bridge.o" -F "$APP/Frameworks" -framework sony2fuji -lc++ -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$APP/viewing-render"
codesign --force --deep --sign - "$APP" >/dev/null
STATUS=0
xcrun simctl spawn "$DEVICE" "$APP/viewing-render" "$OUT" "${RAWLAB_TEST_RAW:-}" || STATUS=$?
python3 - "$OUT" "$DEVICE" "$STATUS" <<'PY_RECEIPT'
import pathlib,json,hashlib,sys
out=pathlib.Path(sys.argv[1]);app=out/'ViewingRenderTests.app'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
(out/'run-receipt.json').write_text(json.dumps({'device':sys.argv[2],'exitCode':int(sys.argv[3]),'appBinarySHA256':sha(app/'viewing-render'),'nativeBinarySHA256':sha(app/'Frameworks/sony2fuji.framework/sony2fuji'),'sources':str(out/'source-receipt.json'),'input':'direct VM calls and real native renders; simulator-spawned executable, not installed UI or touch'},indent=2)+'\n')
PY_RECEIPT
exit "$STATUS"
