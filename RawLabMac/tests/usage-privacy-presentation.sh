#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-usage-ui.XXXXXX")"
trap 'rm -r "$OUT"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx15.0" \
   "$ROOT/RawLabMac/Sources/Presentation/AboutView.swift" \
  "$ROOT/RawLabMac/tests/UsagePrivacyPresentationTests.swift" -o "$OUT/test"
"$OUT/test" "$@"
