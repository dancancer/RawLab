#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-localization.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/Fixture.bundle/Contents/Resources/"{en,de,ja}.lproj
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rawlab.localization-tests</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>' > "$OUT/Fixture.bundle/Contents/Info.plist"
printf '%s\n' '"语言" = "Language";' '"仅英文" = "English fallback";' '"导出 %@ 张" = "Export %@ photos";' > "$OUT/Fixture.bundle/Contents/Resources/en.lproj/Localizable.strings"
printf '%s\n' '"语言" = "Sprache";' > "$OUT/Fixture.bundle/Contents/Resources/de.lproj/Localizable.strings"
printf '%s\n' '"导出 %@ 张" = "%@ 枚を書き出す";' > "$OUT/Fixture.bundle/Contents/Resources/ja.lproj/Localizable.strings"
for client in macos ios; do
    resource_root="$ROOT/RawLabMac/Resources"
    if [ "$client" = ios ]; then resource_root="$ROOT/RawLab/RawLab/Resources"; fi
    mkdir -p "$OUT/$client.bundle/Contents/Resources"
    cp "$OUT/Fixture.bundle/Contents/Info.plist" "$OUT/$client.bundle/Contents/Info.plist"
    for language in en zh-Hans de fr ja es; do
        mkdir -p "$OUT/$client.bundle/Contents/Resources/$language.lproj"
        cp "$resource_root/$language.lproj/Localizable.strings" "$OUT/$client.bundle/Contents/Resources/$language.lproj/"
    done
done
rawlabkit_flags link "$OUT/swiftpm" macos 0
test -f "$RAWLABKIT_BIN/libRawLabKit.a" || { echo 'FAIL: shared localization module is missing'; exit 1; }
swiftc -parse-as-library "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
     "$ROOT/RawLabMac/tests/LocalizationTests.swift" -o "$OUT/test"
"$OUT/test" "$OUT/Fixture.bundle" "$OUT/macos.bundle" "$OUT/ios.bundle"
