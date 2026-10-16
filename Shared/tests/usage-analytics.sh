#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-usage-tests.XXXXXX")"
trap 'rm -r "$TMP"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/UsageAnalytics.swift" \
  "$ROOT/Shared/tests/UsageAnalyticsTests.swift" -o "$TMP/tests"
"$TMP/tests"
