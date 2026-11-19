#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
APP="${1:?Pass the built arm64-simulator RawLab.app absolute path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-subtool-draft.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/coreobjs"
HARNESS="$OUT/SubtoolMenuDraftTests.app"
cp -R "$APP" "$HARNESS"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios18.0-simulator"

python3 - "$HARNESS/Info.plist" <<'PY'
import pathlib, plistlib, sys
info_path = pathlib.Path(sys.argv[1])
app = info_path.parent
info = plistlib.load(info_path.open('rb'))
old = info['CFBundleExecutable']
for name in [old, old + '.debug.dylib']:
    (app / name).unlink(missing_ok=True)
info.update(
    CFBundleIdentifier='com.rawlab.tests.subtool-menu-draft',
    CFBundleExecutable='subtool-menu-draft',
    UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False}
)
plistlib.dump(info, info_path.open('wb'))
PY

xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared" -g '*.swift' -g '!**/tests/**' -g '!**/RawLabKit/**' | sort)
rawlabkit_flags typecheck "$OUT/swiftpm" iphonesimulator 0
xcrun --sdk iphonesimulator swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -enable-testing -c -parse-as-library -emit-module \
    -emit-module-path "$OUT/RawLabSubtoolCoreUI.swiftmodule" -swift-version 5 \
    -module-name RawLabSubtoolCoreUI -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" -output-file-map <(python3 - "$OUT/coreobjs" "${SOURCES[@]}" <<'PY'
import json, pathlib, sys
objdir = pathlib.Path(sys.argv[1])
print(json.dumps({s: {"object": str(objdir / f"{pathlib.Path(s).stem}.o")} for s in sys.argv[2:]}))
PY
)
ar rcs "$OUT/libRawLabSubtoolCoreUI.a" "$OUT/coreobjs"/*.o "$OUT/bridge.o"

rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
xcrun --sdk iphonesimulator swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -swift-version 5 -module-name SubtoolMenuDraftTests \
    -sdk "$SDK" -target "$TARGET" -module-cache-path "$OUT/module-cache" -I "$OUT" \
    -Xcc -I"$ROOT/lutools/include" -Xcc -I"$ROOT/RawLab/RawLab/Support" \
    "$ROOT/RawLab/tests/SubtoolMenuDraftTests.swift" "$OUT/libRawLabSubtoolCoreUI.a" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/subtool-menu-draft"

codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
SIMCTL_CHILD_RAWLAB_SUBTOOL_RESULT="$OUT/result.json" \
    xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" com.rawlab.tests.subtool-menu-draft
python3 - "$OUT/result.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    sys.exit("FAIL: SubtoolMenuDraftTests did not produce result.json")
data = json.loads(path.read_text())
if not data.get("passed"):
    sys.exit(f"FAIL: SubtoolMenuDraftTests reported failure: {data}")
print(f"VERIFIED: {data['checks']} checks passed")
PY
