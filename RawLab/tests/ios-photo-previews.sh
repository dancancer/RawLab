#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -n 1)}"
if [[ -z "$DEVICE" ]]; then
    echo "error: pass a booted iOS Simulator UDID or boot an iOS simulator" >&2
    exit 2
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-photo-previews.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/IOSPhotoPreviewTests.app"
mkdir -p "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
plistlib.dump({
    "CFBundleExecutable": "ios-photo-previews",
    "CFBundleIdentifier": "com.rawlab.tests.ios-photo-previews",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "MinimumOSVersion": "18.0",
}, (app / "Info.plist").open("wb"))
PY
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" \
    "$ROOT/Shared/ProcessingMigration.swift" \
    "$ROOT/Shared/ToneControlsSettings.swift" \
    "$ROOT/Shared/AtmosphereSettings.swift" \
    "$ROOT/Shared/ColorGradingSettings.swift" \
    "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/EditedPhotoPreviewCache.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/CachedPhotoFile.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/RecentPhotoStore.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/IOSPhotoPreviews.swift" \
    "$ROOT/RawLab/tests/IOSPhotoPreviewTests.swift" \
    -o "$APP/ios-photo-previews"
codesign --force --sign - "$APP" >/dev/null
xcrun simctl spawn "$DEVICE" "$APP/ios-photo-previews"
