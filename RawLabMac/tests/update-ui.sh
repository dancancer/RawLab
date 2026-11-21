#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
FIXTURE="${1:?Pass a fixture}"
OUT="${2:?Pass an isolated output directory}"
mkdir -p "$OUT"
rawlab_mac_make_temp_dir STAGE harness "$OUT"
APP="$STAGE/SoftwareUpdateTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - "$ROOT" "$OUT" "$FIXTURE" "${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}/libsony2fuji_core.a" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root, out = map(pathlib.Path, sys.argv[1:3])
names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z',
    'RawLabMac/Sources', 'RawLabMac/Resources', 'RawLabMac/tests/SoftwareUpdateUITests.swift', 'RawLabMac/tests/update-ui.sh', 'Shared'], cwd=root).decode().split('\0')
paths = {str(root/name) for name in names if name} | set(sys.argv[3:])
files = {name: hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() for name in sorted(paths) if pathlib.Path(name).is_file()}
(out/'source-manifest.json').write_text(json.dumps(files, indent=2)+'\n')
PY
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$APP/Contents/MacOS/SoftwareUpdateTests" -- \
    -O -whole-module-optimization -num-threads 4 \
    "$ROOT/RawLabMac/tests/MacUITestRobot.swift" "$ROOT/RawLabMac/tests/SoftwareUpdateUITests.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.rawlab.software-update-tests</string><key>CFBundleExecutable</key><string>SoftwareUpdateTests</string><key>CFBundlePackageType</key><string>APPL</string><key>LSBackgroundOnly</key><true/></dict></plist>
PLIST
for directory in "$ROOT"/RawLabMac/Resources/*.lproj; do cp -R "$directory" "$APP/Contents/Resources/"; done
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
for resource in FilmIcons MasterRecipeIcons MasterRecipes; do cp -R "$ROOT/RawLabMac/Resources/$resource" "$APP/Contents/Resources/"; done
export DYLD_LIBRARY_PATH="$RAWLAB_DEPENDENCY_PREFIX/lib:$RAWLAB_LENS_PREFIX/lib"
python3 - "$OUT" "$APP/Contents/MacOS/SoftwareUpdateTests" "$RAWLAB_DEPENDENCY_PREFIX" "$RAWLAB_LENS_PREFIX" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1]); files = json.loads((out/'source-manifest.json').read_text())
for name, expected in files.items():
    if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() != expected: raise SystemExit('Source changed during UI build: '+name)
paths = [pathlib.Path(sys.argv[2])] + [p for root in sys.argv[3:] for p in (pathlib.Path(root)/'lib').glob('*.dylib')]
(out/'artifact-binding.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, indent=2)+'\n')
PY
"$APP/Contents/MacOS/SoftwareUpdateTests" "$FIXTURE" "$OUT"
