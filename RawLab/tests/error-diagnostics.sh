#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-error-diagnostics.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -sdk "$SDK" "$ROOT/RawLab/RawLab/Core/Persistence/ErrorDiagnostics.swift" \
    "$ROOT/RawLab/tests/ErrorDiagnosticsTests.swift" -o "$OUT/error-diagnostics"
"$OUT/error-diagnostics"
