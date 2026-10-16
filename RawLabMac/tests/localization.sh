#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d /tmp/rawlab-localization.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/Fixture.bundle/Contents/Resources/"{en,de,ja}.lproj
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rawlab.localization-tests</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>' > "$OUT/Fixture.bundle/Contents/Info.plist"
printf '%s\n' '"语言" = "Language";' '"仅英文" = "English fallback";' '"导出 %@ 张" = "Export %@ photos";' > "$OUT/Fixture.bundle/Contents/Resources/en.lproj/Localizable.strings"
printf '%s\n' '"语言" = "Sprache";' > "$OUT/Fixture.bundle/Contents/Resources/de.lproj/Localizable.strings"
printf '%s\n' '"导出 %@ 张" = "%@ 枚を書き出す";' > "$OUT/Fixture.bundle/Contents/Resources/ja.lproj/Localizable.strings"
test -f "$ROOT/Shared/Localization.swift" || { echo 'FAIL: shared localization helper is missing'; exit 1; }
swiftc -swift-version 5 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/Shared/Localization.swift" "$ROOT/RawLabMac/tests/LocalizationTests.swift" -o "$OUT/test"
"$OUT/test" "$OUT/Fixture.bundle"
