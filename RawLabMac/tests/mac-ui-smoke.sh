#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
OUT="${1:?Pass an isolated task output directory}"
SCENARIO="${2:-all}"
mkdir -p "$OUT"
rawlab_mac_make_temp_dir STAGE smoke-app "$OUT"
APP="$STAGE/MacUISmoke.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/module-cache"
RPATHS=()
for dependency in libraw_r opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$APP/Contents/MacOS/MacUISmoke" -- \
    -O -whole-module-optimization -num-threads "${JOBS:-4}" \
    -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLabMac/tests/MacUITestRobot.swift" "$ROOT/RawLabMac/tests/MacUISmokeRunner.swift" \
    "${RPATHS[@]}"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rawlab.mac-ui-smoke</string>
<key>CFBundleExecutable</key><string>MacUISmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do cp -R "$localization" "$APP/Contents/Resources/"; done
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
for resource in FilmIcons MasterRecipeIcons MasterRecipes; do
    mkdir -p "$APP/Contents/Resources/$resource"
    cp -R "$ROOT/RawLabMac/Resources/$resource/." "$APP/Contents/Resources/$resource/"
done
mkdir -p "$APP/Contents/Resources/LUTs"
for lut in "$ROOT"/lutools/flog-2-new/*.cube; do
    case "$lut" in *FLog2-709*|*to_WDR*) continue ;; esac
    cp "$lut" "$APP/Contents/Resources/LUTs/"
done
codesign --force --sign - "$APP"
export DYLD_LIBRARY_PATH="$RAWLAB_DEPENDENCY_PREFIX/lib:$RAWLAB_LENS_PREFIX/lib"
"$APP/Contents/MacOS/MacUISmoke" --scenario "$SCENARIO" --output "$OUT"
