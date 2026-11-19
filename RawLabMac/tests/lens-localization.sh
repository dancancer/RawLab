#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-lens-localization.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/LensLocalization.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/RawLabMac/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Shared/master-recipes.json" "$APP/Contents/Resources/"
cp -R "$ROOT"/RawLabMac/Resources/*.lproj "$APP/Contents/Resources/"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" \
 "$ROOT/RawLabMac/tests/LensLocalizationTests.swift" \
    -o "$APP/Contents/MacOS/LensLocalization"
"$APP/Contents/MacOS/LensLocalization"
