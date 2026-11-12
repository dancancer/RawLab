#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
case "${1:-}" in
    macos)
        python3 RawLabMac/tests/test_build_environment.py
        python3 lutools/tests/test_lens_dependencies.py
        suites=(Shared/tests/edited-photo-preview-cache.sh Shared/tests/hdr-settings.sh Shared/tests/hdr-transfer.sh Shared/tests/hdr-native-request.sh Shared/tests/hdr-source-probe.sh Shared/tests/hdr-display.sh RawLabMac/tests/hdr-model.sh
            RawLabMac/tests/horizontal-picker.sh RawLabMac/tests/mac-viewing.sh
            RawLabMac/tests/control-groups.sh RawLabMac/tests/adjustment-transfer.sh
            RawLabMac/tests/adjustment-transfer-session.sh Shared/tests/adjustment-presets.sh Shared/tests/adjustment-summary.sh
            RawLabMac/tests/adjustment-preset-application.sh Shared/tests/usage-analytics.sh
            Shared/tests/usage-transport.sh RawLabMac/tests/rum-configuration.sh
            RawLabMac/tests/localization.sh RawLabMac/tests/update-check.sh
            RawLabMac/tests/update-install.sh)
        ;;
    ios)
        suites=(Shared/tests/edited-photo-preview-cache.sh Shared/tests/hdr-settings.sh Shared/tests/hdr-transfer.sh Shared/tests/hdr-native-request.sh Shared/tests/hdr-display.sh RawLab/tests/hdr-model.sh
            RawLab/tests/camera-protocol.sh RawLab/tests/camera-originals.sh RawLab/tests/editor-tool-drafts.sh
            RawLab/tests/recent-photos.sh RawLab/tests/presentation.sh RawLab/tests/adjustment-scale.sh RawLab/tests/edit-memory.sh
            RawLab/tests/adjustment-transfer.sh RawLab/tests/adjustment-persistence.sh
            RawLab/tests/adjustment-transfer-session.sh RawLab/tests/batch-export.sh
            Shared/tests/adjustment-presets.sh Shared/tests/adjustment-summary.sh)
        ;;
    *) echo "Usage: $0 macos|ios" >&2; exit 2 ;;
esac
# 仅复用本次运行的编译器模块；测试程序和结果仍由各脚本重新生成。
MODEL_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-apple-models.XXXXXX")"
trap 'rm -rf "$MODEL_CACHE"' EXIT
export RAWLAB_TRANSFER_MODULE_CACHE="$MODEL_CACHE/transfer"
for suite in "${suites[@]}"; do
    printf '[model] %s\n' "$suite"
    bash "$suite"
done
