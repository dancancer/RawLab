#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-settings.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" \
    "$ROOT/Shared/tests/HDRSettingsTests.swift" -o "$BUILD/hdr-settings-tests"
"$BUILD/hdr-settings-tests"
