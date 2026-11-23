#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-agent-hot-reload
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/tests/AgentTransferHotReloadTests.swift"
"$OUT/test" "$@"
