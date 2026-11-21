#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
OUT="${2:-$ROOT/build/compact-ui-evidence}"
FIXTURE="${1:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}"
mkdir -p "$OUT"
rawlab_mac_make_temp_dir STAGE snapshot-run "$OUT"
APP="$STAGE/CompactControlsSnapshots.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/module-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/module-cache"
export SWIFT_MODULECACHE_PATH="$OUT/module-cache"
RPATHS=()
for dependency in libraw_r opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$APP/Contents/MacOS/CompactControlsSnapshots" -- \
    -O -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLabMac/tests/CompactControlsPresentationTests.swift" \
    "${RPATHS[@]}"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rawlab.compact-controls-snapshots</string>
<key>CFBundleExecutable</key><string>CompactControlsSnapshots</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
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
if [[ "${RAWLAB_BUILD_ONLY:-0}" == 1 ]]; then
    trap - EXIT
    echo "Built compact controls snapshot harness without running: $APP"
    exit 0
fi
# Separate processes also isolate SwiftUI/AppKit text caches for each locale.
for language in zh-Hans en de fr ja es; do
    RAWLAB_SNAPSHOT_LANGUAGE="$language" \
        "$APP/Contents/MacOS/CompactControlsSnapshots" "$FIXTURE" "$OUT/$language"
done
