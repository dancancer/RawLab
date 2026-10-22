#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Fresh built RawLab.app}"
DEVICE="${2:?Dedicated task simulator UUID}"
ORIGINAL="${3:?Fresh xctestrun path}"
OUT="${4:?New output directory}"
if [[ -e "$OUT" ]]; then echo "Output already exists: $OUT" >&2; exit 1; fi
mkdir -p "$OUT/source"
OUT="$(cd "$OUT" && pwd)"
HARNESS="$OUT/ViewingEditor.app"
cp -R "$APP" "$HARNESS"
python3 - "$ROOT" "$OUT" "$ORIGINAL" <<'PY'
import pathlib,plistlib,sys,subprocess,shutil,json,hashlib,difflib
root,out,original=map(pathlib.Path,sys.argv[1:]);app=out/'ViewingEditor.app';info=plistlib.load((app/'Info.plist').open('rb'));old=info['CFBundleExecutable']
for name in [old,old+'.debug.dylib']:
 (app/name).unlink(missing_ok=True)
info.update(CFBundleIdentifier='com.rawlab.tests.viewing-editor',CFBundleExecutable='viewing-editor',UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False});plistlib.dump(info,(app/'Info.plist').open('wb'))
transforms={
 'RawLab/RawLab/UI/Editor/ContentView.swift':('        .onAppear {\n            viewModel.loadLUTsIfNeeded()', '        .onAppear {\n            Task { await prepareViewingReview() }\n            viewModel.loadLUTsIfNeeded()'),
 'RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift':('        lastPreviewRequest = request','        MainActor.assumeIsolated { ViewingEditorProbe.shared.recordPreview(request, source: sourceRevision) }\n        lastPreviewRequest = request'),
 'RawLab/RawLab/Core/Persistence/EditPersistence.swift':('        updated[identity.key] = state','        try MainActor.assumeIsolated { try ViewingEditorProbe.shared.recordSave(state) }\n        updated[identity.key] = state'),
 'RawLab/RawLab/UI/Editor/ContentView+Panels.swift':('onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: draftPreviewSettings) }','onPreviewSizeChange: { ViewingEditorProbe.shared.resizing = true; defer { ViewingEditorProbe.shared.resizing = false }; viewModel.updatePreviewSize($0, settings: draftPreviewSettings) }')}
sources=[];diff=[]
for folder in ['RawLab/RawLab/Core','RawLab/RawLab/UI','Shared']:
 for p in (root/folder).rglob('*.swift'):
  if 'tests' in p.relative_to(root).parts:continue
  name=str(p.relative_to(root));text=p.read_text();changed=text
  if name in transforms:
   before,after=transforms[name];assert text.count(before)==1,name;changed=text.replace(before,after)
   diff.extend(difflib.unified_diff(text.splitlines(True),changed.splitlines(True),fromfile=name,tofile='instrumented/'+name))
  dest=out/'source'/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(changed);sources.append((name,hashlib.sha256(p.read_bytes()).hexdigest(),hashlib.sha256(dest.read_bytes()).hexdigest()))
for name in ['RawLab/tests/ViewingEditorHarness.swift','RawLab/tests/ViewingEditorUITests.swift']:
 dest=out/'source'/pathlib.Path(name).name;shutil.copy2(root/name,dest);sources.append((name,hashlib.sha256((root/name).read_bytes()).hexdigest(),hashlib.sha256(dest.read_bytes()).hexdigest()))
(out/'instrumentation.diff').write_text(''.join(diff));(out/'working-tree.diff').write_bytes(subprocess.check_output(['git','diff','--','RawLab'],cwd=root));(out/'source-receipt.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'files':{n:{'original':a,'compiled':b} for n,a,b in sources},'scope':'real ContentView/Core/native; instrumentation only fixture import, receipts and controlled persistence failure; all view/reset/navigation/confirmation uses actual UI'},indent=2)+'\n')
def resolve(v):
 if isinstance(v,str):return v.replace('__TESTROOT__',str(original.resolve().parent))
 if isinstance(v,dict):return {k:resolve(x) for k,x in v.items()}
 if isinstance(v,list):return [resolve(x) for x in v]
 return v
config=resolve(plistlib.load(original.open('rb')));target=config['RawLabUITests'];runner=out/'RawLabUITests-Runner.app';shutil.copytree(target['TestHostPath'],runner)
target.update(TestHostPath=str(runner),TestBundlePath=str(runner/'PlugIns/RawLabUITests.xctest'),UITargetAppPath=str(app),DependentProductPaths=[str(runner),str(runner/'PlugIns/RawLabUITests.xctest'),str(app)])
target['TestingEnvironmentVariables']={'DYLD_FRAMEWORK_PATH':'__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks','DYLD_LIBRARY_PATH':'__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib'}
plistlib.dump(config,(out/'viewing-editor.xctestrun').open('wb'))
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$OUT/source/RawLab/RawLab/Core" "$OUT/source/RawLab/RawLab/UI" "$OUT/source/Shared" -g '*.swift' -g '!**/tests/**' | sort)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -module-name ViewingEditorHarness -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" "$OUT/source/ViewingEditorHarness.swift" "$OUT/bridge.o" -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/viewing-editor"
RUNNER="$OUT/RawLabUITests-Runner.app"
TEST="$RUNNER/PlugIns/RawLabUITests.xctest"
xcrun --sdk iphonesimulator swiftc -emit-library -module-name RawLabUITests -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" -F "$PLATFORM/Developer/Library/Frameworks" -I "$PLATFORM/Developer/usr/lib" -L "$PLATFORM/Developer/usr/lib" -lXCTestSwiftSupport -framework XCTest "$OUT/source/ViewingEditorUITests.swift" -o "$TEST/RawLabUITests"
codesign --force --sign - "$HARNESS" >/dev/null
codesign --force --sign - "$TEST" >/dev/null
codesign --force --sign - "$RUNNER" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
xcrun simctl uninstall "$DEVICE" com.example.RawLabUITests.xctrunner >/dev/null 2>&1 || true
STATUS=0
xcodebuild -xctestrun "$OUT/viewing-editor.xctestrun" -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO -only-testing:"RawLabUITests/ViewingEditorUITests/${RAWLAB_VIEWING_EDITOR_TEST:-testActualCropHandlesAlignWithNativePhotoMargin}" -collect-test-diagnostics never -resultBundlePath "$OUT/viewing-editor.xcresult" test-without-building > "$OUT/viewing-editor-ui.log" 2>&1 || STATUS=$?
python3 - "$OUT" "$DEVICE" "$STATUS" <<'PY'
import pathlib,hashlib,json,sys,subprocess
out=pathlib.Path(sys.argv[1]);app=out/'ViewingEditor.app';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();installed=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',sys.argv[2],'com.rawlab.tests.viewing-editor','app'],text=True).strip())
d={'device':sys.argv[2],'exitCode':int(sys.argv[3]),'sourceReceipt':str(out/'source-receipt.json'),'appSHA256':sha(app/'viewing-editor'),'installedAppSHA256':sha(installed/'viewing-editor'),'nativeSHA256':sha(app/'Frameworks/sony2fuji.framework/sony2fuji'),'installedNativeSHA256':sha(installed/'Frameworks/sony2fuji.framework/sony2fuji'),'testSHA256':sha(out/'RawLabUITests-Runner.app/PlugIns/RawLabUITests.xctest/RawLabUITests'),'scope':'real ContentView + processor + actual XCTest touch; fixture/persistence diagnostics are explicitly instrumented'}
(out/'run-receipt.json').write_text(json.dumps(d,indent=2)+'\n')
PY
exit "$STATUS"
