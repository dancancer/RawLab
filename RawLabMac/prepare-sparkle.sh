#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
CACHE="${RAWLAB_SPARKLE_CACHE:-$(dirname "$COMMON")/.cache/shared/sparkle/2.10.0}"
ARCHIVE="$CACHE/Sparkle-for-Swift-Package-Manager.zip"
EXPECTED=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
mkdir -p "$CACHE"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip \
        -o "$ARCHIVE.download"
    test "$(shasum -a 256 "$ARCHIVE.download" | awk '{print $1}')" = "$EXPECTED"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
test "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$EXPECTED"
FRAMEWORK="$CACHE/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -f "$FRAMEWORK/Sparkle" ]; then
    ditto -x -k "$ARCHIVE" "$CACHE/unpacked"
fi
test -f "$FRAMEWORK/Autoupdate"
test -f "$FRAMEWORK/Updater.app/Contents/MacOS/Updater"
printf '%s\n' "$FRAMEWORK"
