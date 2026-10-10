#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Use a fresh dedicated simulator seeded with DJI_20250602164503_0444_D.DNG}"
OUT="${IOS_UI_OUTPUT:-$ROOT/build/verification/ios-ui-$(date +%Y%m%d-%H%M%S)}"
MEDIA="$HOME/Library/Developer/CoreSimulator/Devices/$IOS_SIMULATOR_UDID/data/Media"
DB="$MEDIA/PhotoData/Photos.sqlite"
mkdir -p "$OUT"
BEFORE="$(sqlite3 -readonly "$DB" 'SELECT COALESCE(MAX(Z_PK), 0) FROM ZASSET;')"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild test -project "$ROOT/RawLab/RawLab.xcodeproj" -scheme RawLab \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -derivedDataPath "$OUT/DerivedData" -resultBundlePath "$OUT/EditorUITests.xcresult" \
    -parallel-testing-enabled NO -only-testing:RawLabUITests/EditorUITests \
    > "$OUT/EditorUITests.log" 2>&1
# Verify new simulator files from the host; the UI runner needs no Photos access.
sqlite3 -readonly -json "$DB" \
    "SELECT Z_PK, ZDIRECTORY, ZFILENAME, ZWIDTH, ZHEIGHT FROM ZASSET WHERE Z_PK > $BEFORE AND ZUNIFORMTYPEIDENTIFIER = 'public.jpeg' ORDER BY Z_PK;" \
    > "$OUT/exported-assets.json"
jq -e 'any(.[]; ([.ZWIDTH, .ZHEIGHT] | max) == 128) and any(.[]; ([.ZWIDTH, .ZHEIGHT] | max) == 1024) and any(.[]; ([.ZWIDTH, .ZHEIGHT] | max) == 3072)' \
    "$OUT/exported-assets.json" > /dev/null
while IFS=$'\t' read -r directory filename width height; do
    file="$MEDIA/$directory/$filename"
    sips -g pixelWidth -g pixelHeight "$file" > "$OUT/$filename-size.txt"
    actual_width="$(awk '/pixelWidth:/ { print $2 }' "$OUT/$filename-size.txt")"
    actual_height="$(awk '/pixelHeight:/ { print $2 }' "$OUT/$filename-size.txt")"
    test "$actual_width" = "$width"
    test "$actual_height" = "$height"
done < <(jq -r '.[] | [.ZDIRECTORY, .ZFILENAME, .ZWIDTH, .ZHEIGHT] | @tsv' "$OUT/exported-assets.json")
printf 'PASS: Editor UI workflows and decoded Photos exports (128 / 1024 / original 3072 px); artifacts: %s\n' "$OUT"
