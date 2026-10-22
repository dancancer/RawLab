#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${1:?Existing immutable ViewingEditor harness output}"
DEVICE="${2:?Dedicated simulator UUID}"
OUT="${3:?New output directory}"
if [[ -e "$OUT" ]]; then echo "Output already exists: $OUT" >&2; exit 1; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cp -R "$BASE/ViewingEditor.app" "$BASE/RawLabUITests-Runner.app" "$OUT/"
cp "$ROOT/RawLab/tests/ViewingEditorUITests.swift" "$OUT/ViewingEditorUITests.swift"
python3 - "$BASE" "$OUT" <<'PY'
import pathlib,plistlib,sys,os
base,out=map(pathlib.Path,sys.argv[1:]);config=plistlib.load((base/'viewing-editor.xctestrun').open('rb'))
def relocate(v):
 if isinstance(v,str):return v.replace(str(base),str(out))
 if isinstance(v,list):return [relocate(x) for x in v]
 if isinstance(v,dict):return {k:relocate(x) for k,x in v.items()}
 return v
config=relocate(config)
config['RawLabUITests'].setdefault('TestingEnvironmentVariables',{}).update(S3_VIEWING_LANGUAGE=os.environ.get('S3_VIEWING_LANGUAGE','en'),S3_VIEWING_TEXT=os.environ.get('S3_VIEWING_TEXT',''))
plistlib.dump(config,(out/'viewing-editor.xctestrun').open('wb'))
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
RUNNER="$OUT/RawLabUITests-Runner.app"
TEST="$RUNNER/PlugIns/RawLabUITests.xctest"
xcrun --sdk iphonesimulator swiftc -emit-library -module-name RawLabUITests -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-cache-path "$OUT/module-cache" -F "$PLATFORM/Developer/Library/Frameworks" -I "$PLATFORM/Developer/usr/lib" -L "$PLATFORM/Developer/usr/lib" -lXCTestSwiftSupport -framework XCTest "$OUT/ViewingEditorUITests.swift" -o "$TEST/RawLabUITests"
codesign --force --sign - "$TEST" >/dev/null
codesign --force --sign - "$RUNNER" >/dev/null
xcrun simctl install "$DEVICE" "$OUT/ViewingEditor.app"
xcrun simctl uninstall "$DEVICE" com.example.RawLabUITests.xctrunner >/dev/null 2>&1 || true
STATUS=0
xcodebuild -xctestrun "$OUT/viewing-editor.xctestrun" -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO -only-testing:"RawLabUITests/ViewingEditorUITests/${RAWLAB_VIEWING_EDITOR_TEST:?Choose exact test}" -collect-test-diagnostics never -resultBundlePath "$OUT/viewing-editor.xcresult" test-without-building > "$OUT/viewing-editor-ui.log" 2>&1 || STATUS=$?
python3 - "$BASE" "$OUT" "$DEVICE" "$STATUS" <<'PY'
import pathlib,hashlib,json,sys,subprocess
base,out=map(pathlib.Path,sys.argv[1:3]);installed=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',sys.argv[3],'com.rawlab.tests.viewing-editor','app'],text=True).strip());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
app=out/'ViewingEditor.app';original=base/'ViewingEditor.app';assert sha(app/'viewing-editor')==sha(original/'viewing-editor')
d={'sourceReceipt':str(base/'source-receipt.json'),'compiledAppIdenticalTo':str(original),'testSourceSHA256':sha(out/'ViewingEditorUITests.swift'),'testBinarySHA256':sha(out/'RawLabUITests-Runner.app/PlugIns/RawLabUITests.xctest/RawLabUITests'),'appSHA256':sha(app/'viewing-editor'),'installedAppSHA256':sha(installed/'viewing-editor'),'nativeSHA256':sha(app/'Frameworks/sony2fuji.framework/sony2fuji'),'device':sys.argv[3],'exitCode':int(sys.argv[4]),'scope':'same full ContentView+native binary, new exact directed XCTest driver'}
(out/'run-receipt.json').write_text(json.dumps(d,indent=2)+'\n')
PY
exit "$STATUS"
