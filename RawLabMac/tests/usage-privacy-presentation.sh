#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-usage-ui.XXXXXX")"
trap 'rm -r "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx15.0" \
  "$ROOT/Shared/Localization.swift" \
  "$ROOT/Shared/UsageAnalytics.swift" "$ROOT/RawLabMac/Sources/UpdateRelease.swift" \
  "$ROOT/RawLabMac/Sources/UpdateChecker.swift" "$ROOT/RawLabMac/Sources/AboutView.swift" \
  "$ROOT/RawLabMac/tests/UsagePrivacyPresentationTests.swift" -o "$OUT/test"
"$OUT/test" "$@"
