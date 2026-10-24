#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="${1:-$ROOT/build/lens-draft-ui-evidence}"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/snapshot-run.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LensDraftSnapshots.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/module-cache"
RPATHS=()
for dependency in libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4; do
    RPATHS+=(-Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir "$dependency")")
done
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
    -module-cache-path "$STAGE/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ToneControlsNative.swift" \
    "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Lens/MacLensPresentation.swift" "$ROOT/RawLabMac/Sources/Lens/LensControls.swift" \
    "$ROOT/RawLabMac/tests/MacLensDraftPresentationTests.swift" "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal "${RPATHS[@]}" \
    -o "$APP/Contents/MacOS/LensDraftSnapshots"
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
