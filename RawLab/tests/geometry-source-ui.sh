#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated large iPad simulator UDID}"
ORIGINAL_XCTESTRUN="${3:?Pass the build-for-testing .xctestrun path}"
OUT="${4:?Pass a new output directory}"
if [[ -e "$OUT" ]]; then echo "Output already exists: $OUT" >&2; exit 1; fi
mkdir -p "$OUT/source"
OUT="$(cd "$OUT" && pwd)"
HARNESS="$OUT/GeometrySourceHarness.app"
cp -R "$APP" "$HARNESS"
ORIGINAL_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$HARNESS/Info.plist")"
rm -f "$HARNESS/$ORIGINAL_EXECUTABLE"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.geometry-source' \
    -c 'Set CFBundleExecutable geometry-source' "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete UIApplicationSceneManifest' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c 'Add UIApplicationSceneManifest dict' \
    -c 'Add UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication array' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0 dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneConfigurationName string Geometry Source Review' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName string GeometrySourceHarness.GeometrySourceSceneDelegate' \
    "$HARNESS/Info.plist"
python3 - "$ROOT" "$OUT" "$ORIGINAL_XCTESTRUN" <<'PY'
import difflib, json, pathlib, plistlib, subprocess, sys
root, out, original = map(pathlib.Path, sys.argv[1:])
transforms = {
    "ContentView.swift": ("        .onAppear {\n            viewModel.loadLUTsIfNeeded()",
                          "        .onAppear {\n            Task { await self.runGeometrySourceReview() }\n            viewModel.loadLUTsIfNeeded()"),
    "ContentView+Panels.swift": ("onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: draftPreviewSettings) }",
                                "onPreviewSizeChange: { GeometrySourceProbe.shared.viewportEdges.append($0); viewModel.updatePreviewSize($0, settings: draftPreviewSettings) }")
}
diffs = []
for name, (before, after) in transforms.items():
    source = root / "RawLab/RawLab/UI" / name
    text = source.read_text()
    if text.count(before) != 1:
        raise SystemExit(f"Expected exactly one marker in {source}")
    changed = text.replace(before, after)
    target = out / "source" / name
    target.write_text(changed)
    diffs.extend(difflib.unified_diff(text.splitlines(True), changed.splitlines(True), fromfile=str(source), tofile=str(target)))
(out / "instrumentation.diff").write_text("".join(diffs))
(out / "source-head.txt").write_text(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True))
(out / "working-tree.diff").write_bytes(subprocess.check_output(["git", "diff", "--", "RawLab"], cwd=root))
def relocate(value):
    if isinstance(value, str): return value.replace("__TESTROOT__", str(original.resolve().parent))
    if isinstance(value, dict): return {k: relocate(v) for k, v in value.items()}
    if isinstance(value, list): return [relocate(v) for v in value]
    return value
config = relocate(plistlib.loads(original.read_bytes()))
target = config["RawLabUITests"]
for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    target.setdefault(key, {})["RAWLAB_GEOMETRY_SOURCE_HARNESS"] = "1"
(out / "geometry-source.xctestrun").write_bytes(plistlib.dumps(config))
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do
    case "$file" in
        */ContentView.swift|*/ContentView+Panels.swift) ;;
        *) SOURCES+=("$file") ;;
    esac
done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared" -g '*.swift' | sort)
cp "$ROOT/RawLab/tests/GeometrySourceHarness.swift" "$OUT/source/GeometrySourceHarness.swift"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -module-name GeometrySourceHarness -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$OUT/source/ContentView.swift" "$OUT/source/ContentView+Panels.swift" \
    "$OUT/source/GeometrySourceHarness.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/geometry-source"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
if xcodebuild -xctestrun "$OUT/geometry-source.xctestrun" \
    -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO \
    -only-testing:RawLabUITests/EditorV4UITests/testGeometrySourceRestorationUsesUncroppedPreview \
    -collect-test-diagnostics never -resultBundlePath "$OUT/geometry-source.xcresult" \
    test-without-building > "$OUT/geometry-source-ui.log" 2>&1; then
    TEST_STATUS=0
else
    TEST_STATUS=$?
fi
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" com.rawlab.tests.geometry-source data)"
if [[ -f "$CONTAINER/Documents/geometry-source.json" ]]; then
    cp "$CONTAINER/Documents/geometry-source.json" "$OUT/geometry-source.json"
fi
echo "Geometry source test artifacts: $OUT"
exit "$TEST_STATUS"
