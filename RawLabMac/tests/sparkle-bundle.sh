#!/bin/bash
set -euo pipefail
APP="${1:?Pass the built app bundle}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
test -L "$FRAMEWORK/Versions/Current"
test -f "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
for relative in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater \
    XPCServices/Downloader.xpc/Contents/MacOS/Downloader XPCServices/Installer.xpc/Contents/MacOS/Installer; do
    binary="$FRAMEWORK/$relative"
    test -x "$binary"
    if [ -n "${RAWLAB_ARCH:-}" ]; then lipo "$binary" -verify_arch "$RAWLAB_ARCH"; fi
    codesign --verify --strict "$binary"
done
codesign --verify --deep --strict "$FRAMEWORK"
otool -L "$APP/Contents/MacOS/RawLabMac" | grep -F '@rpath/Sparkle.framework/' >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$APP/Contents/Info.plist")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$APP/Contents/Info.plist")" = false
echo 'PASS: pinned Sparkle framework, helpers, signatures and disabled framework scheduling'
