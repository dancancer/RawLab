#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-lens-localization
APP="$OUT/LensLocalization.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/RawLabMac/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
cp -R "$ROOT"/RawLabMac/Resources/*.lproj "$APP/Contents/Resources/"
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
    "$ROOT/RawLabMac/tests/LensLocalizationTests.swift" \
    -o "$APP/Contents/MacOS/LensLocalization"
"$APP/Contents/MacOS/LensLocalization"
