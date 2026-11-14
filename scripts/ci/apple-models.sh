#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
# 不变量 7：套件日志出现行首 SKIP 标记即视为能力未演练，即使退出码为 0 也判败。
# 锚定行首是为了不误伤路径段、编译器诊断、标识符或 PASS 文案里的合法 "SKIP" 字样。
fail_on_logged_skip() {
    if grep -q -E '^[[:space:]]*SKIP([[:space:]:]|$)' "$1"; then
        printf 'error: %s logged SKIP (forbidden by CI invariant 7)\n' "$2" >&2
        exit 1
    fi
}
case "${1:-}" in
    macos)
        pre_checks=(RawLabMac/tests/test_build_environment.py lutools/tests/test_lens_dependencies.py)
        # HDR 渲染重置按钮契约由不依赖辅助功能授权的 hdr-rendition-reset.sh 覆盖；
        # 依赖 AXUIElement 的 hdr-rendition-ui.sh 保留为本地/发布前手工检查，CI 不执行。
        suites=(Shared/tests/edited-photo-preview-cache.sh Shared/tests/hdr-settings.sh Shared/tests/hdr-transfer.sh Shared/tests/hdr-native-request.sh Shared/tests/hdr-source-probe.sh Shared/tests/hdr-display.sh RawLabMac/tests/hdr-model.sh RawLabMac/tests/hdr-rendition-reset.sh
            RawLabMac/tests/horizontal-picker.sh RawLabMac/tests/mac-viewing.sh
            RawLabMac/tests/control-groups.sh RawLabMac/tests/adjustment-transfer.sh
            RawLabMac/tests/reset-scenarios.sh
            RawLabMac/tests/adjustment-transfer-session.sh Shared/tests/adjustment-presets.sh Shared/tests/adjustment-summary.sh
            RawLabMac/tests/adjustment-preset-application.sh Shared/tests/usage-analytics.sh
            Shared/tests/usage-transport.sh RawLabMac/tests/rum-configuration.sh
            RawLabMac/tests/localization.sh RawLabMac/tests/update-check.sh
            RawLabMac/tests/update-install.sh)
        ;;
    ios)
        pre_checks=()
        suites=(Shared/tests/edited-photo-preview-cache.sh Shared/tests/hdr-settings.sh Shared/tests/hdr-transfer.sh Shared/tests/hdr-native-request.sh Shared/tests/hdr-display.sh RawLab/tests/hdr-model.sh RawLab/tests/hdr-resource-notice.sh
            RawLab/tests/camera-protocol.sh RawLab/tests/camera-originals.sh RawLab/tests/editor-tool-drafts.sh
            RawLab/tests/ios-reset-entry-ui.sh
            RawLab/tests/recent-photos.sh RawLab/tests/presentation.sh RawLab/tests/adjustment-scale.sh RawLab/tests/edit-memory.sh
            RawLab/tests/adjustment-transfer.sh RawLab/tests/reset-scenarios.sh RawLab/tests/adjustment-persistence.sh
            RawLab/tests/adjustment-transfer-session.sh RawLab/tests/batch-export.sh
            Shared/tests/adjustment-presets.sh Shared/tests/adjustment-summary.sh)
        ;;
    *) echo "Usage: $0 macos|ios" >&2; exit 2 ;;
esac
# 仅复用本次运行的编译器模块；测试程序和结果仍由各脚本重新生成。
MODEL_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-apple-models.XXXXXX")"
trap 'rm -rf "$MODEL_CACHE"' EXIT
export RAWLAB_TRANSFER_MODULE_CACHE="$MODEL_CACHE/transfer"
for pre in ${pre_checks[@]+"${pre_checks[@]}"}; do
    printf '[check] %s\n' "$pre"
    pre_log="$MODEL_CACHE/suite.log"
    python3 "$pre" 2>&1 | tee "$pre_log"
    fail_on_logged_skip "$pre_log" "$pre"
done
for suite in "${suites[@]}"; do
    printf '[model] %s\n' "$suite"
    suite_log="$MODEL_CACHE/suite.log"
    bash "$suite" 2>&1 | tee "$suite_log"
    fail_on_logged_skip "$suite_log" "$suite"
done
