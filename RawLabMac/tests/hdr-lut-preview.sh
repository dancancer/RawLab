#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$#" -eq 0 ]; then
    set -- "${RAWLAB_TEST_HDR:?Pass read-only HDR original paths or set RAWLAB_TEST_HDR}"
fi
exec bash "$ROOT/RawLabMac/tests/lut-preview.sh" "$@"
