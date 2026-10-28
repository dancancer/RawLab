#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
case "${1:-}" in
    macos)
        python3 RawLabMac/tests/test_photo_copy.py
        python3 RawLabMac/tests/test_build_environment.py
        python3 lutools/tests/test_lens_dependencies.py
        suites=(RawLabMac/tests/horizontal-picker.sh RawLabMac/tests/mac-viewing.sh
            RawLabMac/tests/control-groups.sh RawLabMac/tests/adjustment-transfer.sh
            RawLabMac/tests/adjustment-transfer-session.sh Shared/tests/adjustment-presets.sh
            RawLabMac/tests/adjustment-preset-application.sh Shared/tests/usage-analytics.sh
            Shared/tests/usage-transport.sh RawLabMac/tests/rum-configuration.sh
            RawLabMac/tests/localization.sh RawLabMac/tests/update-check.sh
            RawLabMac/tests/update-install.sh)
        ;;
    ios)
        suites=(RawLab/tests/presentation.sh RawLab/tests/adjustment-scale.sh RawLab/tests/edit-memory.sh
            RawLab/tests/adjustment-transfer.sh RawLab/tests/adjustment-persistence.sh
            RawLab/tests/adjustment-transfer-session.sh Shared/tests/adjustment-presets.sh)
        ;;
    *) echo "Usage: $0 macos|ios" >&2; exit 2 ;;
esac
for suite in "${suites[@]}"; do
    printf '[model] %s\n' "$suite"
    bash "$suite"
done
