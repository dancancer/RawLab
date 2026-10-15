#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
OUT="${3:?Pass a new output directory}"
if [[ -e "$OUT" ]]; then echo "Output directory already exists: $OUT" >&2; exit 1; fi
HARNESS="$OUT/PickerCancelHarness.app"
mkdir -p "$HARNESS" "$OUT/source"
cp -R "$APP/." "$HARNESS/"
ORIGINAL_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$HARNESS/Info.plist")"
rm -f "$HARNESS/$ORIGINAL_EXECUTABLE"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.picker-cancel' \
    -c 'Set CFBundleExecutable picker-cancel-harness' "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete UIApplicationSceneManifest' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Delete UILaunchStoryboardName' "$HARNESS/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c 'Add UIApplicationSceneManifest dict' \
    -c 'Add UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication array' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0 dict' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneConfigurationName string Picker Cancel Harness' \
    -c 'Add UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName string PickerCancelHarness.PickerCancelSceneDelegate' \
    "$HARNESS/Info.plist"
/usr/bin/python3 - "$ROOT" "$OUT" <<'PY'
import difflib, hashlib, json, pathlib, subprocess, sys
root, out = map(pathlib.Path, sys.argv[1:])
transforms = {
    "RawLab/RawLab/UI/ContentView.swift": [
        ("        .onAppear {\n            viewModel.loadLUTsIfNeeded()",
         "        .onAppear {\n            PickerCancelHarnessState.shared.readEditor = { self.pickerCancelSnapshot() }\n            viewModel.loadLUTsIfNeeded()"),
        ("        .onDisappear { cancelRulerFocus(); cancelPhotoImport() }",
         "        .onDisappear { cancelRulerFocus(); cancelPhotoImport(); PickerCancelHarnessState.shared.disappearances += 1 }")
    ],
    "RawLab/RawLab/UI/ContentView+Helpers.swift": [
        ("try await PhotoImportFile.loadSource { try await PhotoImportFile.load(from: item) }",
         "try await PhotoImportFile.loadSource { try await PickerCancelHarnessState.shared.acquire(item) }")
    ]
}
manifest = {"sourceHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(), "copies": []}
diffs = []
for name, replacements in transforms.items():
    source = (root / name).read_text()
    changed = source
    for before, after in replacements:
        count = changed.count(before)
        if count != 1:
            raise SystemExit(f"Expected exactly one marker in {name}, found {count}: {before!r}")
        changed = changed.replace(before, after)
    target = out / "source" / pathlib.Path(name).name
    target.write_text(changed)
    diffs.extend(difflib.unified_diff(source.splitlines(True), changed.splitlines(True), fromfile=name, tofile=str(target)))
    manifest["copies"].append({"source": name, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(), "copy": str(target), "copySHA256": hashlib.sha256(changed.encode()).hexdigest(), "replacements": len(replacements)})
(out / "source-instrumentation.diff").write_text("".join(diffs))
(out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do
    case "$file" in
        */ContentView.swift|*/ContentView+Helpers.swift) ;;
        *) SOURCES+=("$file") ;;
    esac
done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared" -g '*.swift' | sort)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -module-name PickerCancelHarness -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$OUT/source/ContentView.swift" "$OUT/source/ContentView+Helpers.swift" \
    "$ROOT/RawLab/tests/PickerCancelHarness.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/picker-cancel-harness"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
echo "Picker cancellation harness installed: $HARNESS"
echo "Source instrumentation: $OUT/source-instrumentation.diff"
