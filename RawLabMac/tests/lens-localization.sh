#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-lens-localization.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/LensLocalization.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/RawLabMac/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
cp -R "$ROOT"/RawLabMac/Resources/*.lproj "$APP/Contents/Resources/"
swiftc -swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" "$ROOT/RawLabMac/tests/LensLocalizationTests.swift" \
    -o "$APP/Contents/MacOS/LensLocalization"
"$APP/Contents/MacOS/LensLocalization"
