#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
DEVICE="${1:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -n 1)}"
if [[ -z "$DEVICE" ]]; then
    echo "error: pass a booted iOS Simulator UDID or boot an iOS simulator" >&2
    exit 2
fi
rawlab_ios_make_temp_dir OUT rawlab-ios-photo-previews
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
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/Core/Persistence/IOSPhotoPreviews.swift" \
    "$ROOT/RawLab/tests/IOSPhotoPreviewTests.swift" \
    -o "$APP/ios-photo-previews"
codesign --force --sign - "$APP" >/dev/null
xcrun simctl spawn "$DEVICE" "$APP/ios-photo-previews"
