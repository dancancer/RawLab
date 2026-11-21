#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
APP="$ROOT/build/RawLab Mac.app"
rawlab_mac_make_temp_dir WORK rawlab-icon-test
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
test "$NAME" = AppIcon
iconutil -c iconset "$APP/Contents/Resources/$NAME.icns" -o "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        if [ "$scale" = 2 ]; then suffix="@2x"; fi
        file="$WORK/AppIcon.iconset/icon_${size}x${size}${suffix}.png"
        expected=$((size * scale))
        width="$(sips -g pixelWidth "$file" | awk '/pixelWidth:/ {print $2}')"
        height="$(sips -g pixelHeight "$file" | awk '/pixelHeight:/ {print $2}')"
        test "$width" = "$expected"
        test "$height" = "$expected"
        sips -g hasAlpha "$file" | grep -q 'hasAlpha: yes'
        echo "PASS: icon ${size}pt at ${scale}x is ${expected}px RGBA"
    done
done
codesign --verify --deep --strict "$APP"
echo 'PASS: bundle icon registration and app signature'
