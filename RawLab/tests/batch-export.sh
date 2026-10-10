#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-batch.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -sdk "$SDK" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/BatchExportCore.swift" \
    "$ROOT/RawLab/tests/BatchExportTests.swift" \
    -o "$OUT/batch-export"
"$OUT/batch-export"
