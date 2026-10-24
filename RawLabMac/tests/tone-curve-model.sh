#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-curve-model.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/RawLabMac/tests/ToneCurveModelTests.swift" -o "$OUT/tests"
"$OUT/tests"
swiftc -swift-version 5 "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/ToneCurveInteraction.swift" \
    "$ROOT/Shared/tests/ToneCurveInteractionTests.swift" -o "$OUT/interaction"
"$OUT/interaction"
