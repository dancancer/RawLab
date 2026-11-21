#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
OUT="${1:-$ROOT/build/lens-draft-ui-evidence}"
mkdir -p "$OUT"
rawlab_mac_make_temp_dir STAGE snapshot-run "$OUT"
APP="$STAGE/LensDraftSnapshots.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/module-cache"
RPATHS=()
for dependency in libraw_r opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$APP/Contents/MacOS/LensDraftSnapshots" -- \
    -module-cache-path "$STAGE/module-cache" \
    "$ROOT/RawLabMac/Sources/Lens/MacLensPresentation.swift" "$ROOT/RawLabMac/Sources/Lens/LensControls.swift" \
    "$ROOT/RawLabMac/tests/MacLensDraftPresentationTests.swift" "${RPATHS[@]}"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rawlab.lens-draft-snapshots</string>
<key>CFBundleExecutable</key><string>LensDraftSnapshots</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
for localization in "$ROOT"/RawLabMac/Resources/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
for language in zh-Hans en de fr ja es; do
    RAWLAB_SNAPSHOT_LANGUAGE="$language" "$APP/Contents/MacOS/LensDraftSnapshots" "$OUT/$language"
done
