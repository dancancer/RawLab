#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hsl-target.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" \
    "$ROOT/Shared/tests/HSLTargetAdjustmentTests.swift" -o "$OUT/test"
"$OUT/test"
