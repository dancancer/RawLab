#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
# 不变量 7：套件日志出现行首 SKIP 标记即视为能力未演练，即使退出码为 0 也判败。
# 锚定行首是为了不误伤路径段、编译器诊断、标识符或 PASS 文案里的合法 "SKIP" 字样。
# 唯一例外（docs/process/ci.md）：models 清单内的混合 AX 套件（其 Swift 二层闸与
# ax-gate.sh 三态文案同源）在无辅助功能授权且未设 RAWLAB_REQUIRE_AX 时，30 条不依赖
# AX 的模型断言照常真跑，仅 AX 分支打固定两行诚实 SKIP；仅当脚本在白名单内且固定
# SKIP 文案与 ::warning:: 注解同场时放行，白名单外的 SKIP 一律照旧判败；
# 设了 RAWLAB_REQUIRE_AX 时闸以 FAIL exit 1 出场，不产生 SKIP，三态不破。
AX_HONEST_SKIP_SUITES=(RawLab/tests/ios-reset-entry-ui.sh)
AX_GATE_SKIP_LINE="SKIP: accessibility is not trusted here; the AX checks did not run"
ax_honest_skip_allowed() {
    local suite="$1" log="$2" known
    for known in ${AX_HONEST_SKIP_SUITES[@]+"${AX_HONEST_SKIP_SUITES[@]}"}; do
        [ "$suite" = "$known" ] || continue
        # 只放行闸自己的两行：行首 SKIP 标记必须恰有一行且就是固定文案，::warning:: 孪生行
        # 同场；夹带的任何其他行首 SKIP（计数>1，或固定文案缺席）仍按不变量 7 判败。
        [ "$(grep -c -E '^[[:space:]]*SKIP([[:space:]:]|$)' "$log")" = 1 ] || return 1
        grep -qxF "$AX_GATE_SKIP_LINE" "$log" || return 1
        grep -qxF "::warning::$AX_GATE_SKIP_LINE" "$log" || return 1
        return 0
    done
    return 1
}
# 并行回放的日志很长，失败套件名与退出码要单独汇总到 stderr，免得在 CI 日志里逐段翻找。
failed_suites=()
fail_on_logged_skip() {
    if grep -q -E '^[[:space:]]*SKIP([[:space:]:]|$)' "$1"; then
        ax_honest_skip_allowed "$2" "$1" && return 0
        printf 'error: %s logged SKIP (forbidden by CI invariant 7)\n' "$2" >&2
        failed_suites+=("$2 (logged SKIP)")
        return 1
    fi
}
case "${1:-}" in
    macos)
        python3 "$ROOT/scripts/assets/prepare.py" --group luts --quiet
        pre_checks=(RawLabMac/tests/test_build_environment.py lutools/tests/test_lens_dependencies.py)
        # HDR 渲染重置按钮契约由不依赖辅助功能授权的 hdr-rendition-reset.sh 覆盖；
        # 依赖 AXUIElement 的 hdr-rendition-ui.sh 保留为本地/发布前手工检查，CI 不执行。
        suites=(Shared/tests/hdr-native-typecheck.sh Shared/tests/hdr-native-request.sh Shared/tests/hdr-source-probe.sh Shared/tests/color-grading-interaction.sh
            RawLabMac/tests/hdr-model.sh RawLabMac/tests/hdr-canvas.sh RawLabMac/tests/hdr-rendition-reset.sh
            RawLabMac/tests/horizontal-picker.sh RawLabMac/tests/mac-viewing.sh
            RawLabMac/tests/control-groups.sh RawLabMac/tests/adjustment-transfer.sh
            RawLabMac/tests/reset-scenarios.sh
            RawLabMac/tests/edit-records.sh
            RawLabMac/tests/adjustment-transfer-session.sh
            RawLabMac/tests/adjustment-preset-application.sh RawLabMac/tests/rum-configuration.sh
            RawLabMac/tests/localization.sh
            RawLabMac/tests/update-install.sh RawLabMac/tests/thumbnail-cache.sh
            RawLabMac/tests/geometry-settings.sh RawLabMac/tests/master-recipe.sh
            RawLabMac/tests/lens-localization.sh RawLabMac/tests/chroma-settings.sh
            RawLabMac/tests/wavelet-settings.sh RawLabMac/tests/workspace-browser.sh
            RawLabMac/tests/workspace-layout.sh RawLabMac/tests/render-scheduling.sh
            RawLabMac/tests/histogram.sh RawLabMac/tests/mac-crop-interaction.sh
            RawLabMac/tests/mac-inspection-suite.sh
            RawLabMac/tests/update-trust.sh RawLabMac/tests/usage-privacy-presentation.sh)
        ;;
    ios)
        pre_checks=(scripts/rum/test_embed_ios.py)
        suites=(Shared/tests/hdr-native-typecheck.sh Shared/tests/hdr-native-request.sh Shared/tests/color-grading-interaction.sh
            RawLab/tests/hdr-model.sh RawLab/tests/hdr-canvas.sh RawLab/tests/hdr-resource-notice.sh
            RawLab/tests/camera-protocol.sh RawLab/tests/camera-originals.sh RawLab/tests/retention.sh RawLab/tests/editor-tool-drafts.sh
            RawLab/tests/editor-coordinator.sh RawLab/tests/ios-reset-entry-ui.sh
            RawLab/tests/ios-inspection-suite.sh
            RawLab/tests/recent-photos.sh RawLab/tests/presentation.sh RawLab/tests/adjustment-scale.sh RawLab/tests/edit-memory.sh
            RawLab/tests/adjustment-transfer.sh RawLab/tests/reset-scenarios.sh RawLab/tests/edit-records.sh RawLab/tests/adjustment-persistence.sh
            RawLab/tests/adjustment-transfer-session.sh RawLab/tests/batch-export.sh
            RawLab/tests/error-diagnostics.sh RawLab/tests/rum-configuration.sh RawLab/tests/rum-threading.sh RawLab/tests/rum-transport.sh
            RawLab/tests/system-open.sh RawLab/tests/viewing-state.sh RawLab/tests/lut-library-selection.sh)
        ;;
    *) echo "Usage: $0 macos|ios" >&2; exit 2 ;;
esac
# 仅复用本次运行的编译器模块；测试程序和结果仍由各脚本重新生成。
_tmp_base="${TMPDIR:-/tmp}"
while [[ "$_tmp_base" == */ && "$_tmp_base" != "/" ]]; do
    _tmp_base="${_tmp_base%/}"
done
: "${_tmp_base:=/}"
MODEL_CACHE="$(mktemp -d "${_tmp_base%/}/rawlab-apple-models.XXXXXX")"
pids=()
idxs=()
_apple_models_cleaned=0
_collect_process_tree() {
    local target="$1"
    local child children
    printf '%s\n' "$target"
    children="$(pgrep -P "$target" 2>/dev/null || true)"
    if [[ -n "$children" ]]; then
        while IFS= read -r child; do
            [[ -n "$child" ]] || continue
            _collect_process_tree "$child"
        done <<< "$children"
    fi
}
cleanup_apple_models() {
    local pid p tree_line
    local all_pids=()
    if [ "$_apple_models_cleaned" -eq 1 ]; then
        return 0
    fi
    _apple_models_cleaned=1
    for pid in ${pids[@]+"${pids[@]}"}; do
        while IFS= read -r tree_line; do
            [[ -n "$tree_line" ]] || continue
            all_pids+=("$tree_line")
        done <<< "$(_collect_process_tree "$pid")"
    done
    for p in ${all_pids[@]+"${all_pids[@]}"}; do
        kill -TERM "$p" 2>/dev/null || true
    done
    for pid in ${pids[@]+"${pids[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
    local tries=0
    while [ "$tries" -lt 50 ]; do
        local any_alive=0
        for p in ${all_pids[@]+"${all_pids[@]}"}; do
            if kill -0 "$p" 2>/dev/null; then
                any_alive=1
                break
            fi
        done
        [ "$any_alive" -eq 0 ] && break
        sleep 0.02
        tries=$((tries + 1))
    done
    rm -rf "$MODEL_CACHE"
}
trap cleanup_apple_models EXIT
trap 'cleanup_apple_models; exit 130' INT
trap 'cleanup_apple_models; exit 143' TERM
export RAWLAB_TRANSFER_MODULE_CACHE="$MODEL_CACHE/transfer"
if [[ -n "${RAWLAB_CI_SWIFTPM_CACHE:-}" ]]; then
    _ci_swiftpm_cache="$RAWLAB_CI_SWIFTPM_CACHE"
    if [[ "$_ci_swiftpm_cache" != /* ]]; then
        _ci_swiftpm_cache="$ROOT/$_ci_swiftpm_cache"
    fi
    mkdir -p "$_ci_swiftpm_cache/deps" "$_ci_swiftpm_cache/tests"
    export RAWLAB_SWIFTPM_CACHE="$_ci_swiftpm_cache/deps"
    SWIFTPM_TEST_SCRATCH="$_ci_swiftpm_cache/tests"
else
    export RAWLAB_SWIFTPM_CACHE="$MODEL_CACHE/swiftpm"
    SWIFTPM_TEST_SCRATCH="$MODEL_CACHE/swiftpm-tests"
fi

for pre in ${pre_checks[@]+"${pre_checks[@]}"}; do
    printf '[check] %s\n' "$pre"
    pre_log="$MODEL_CACHE/pre.log"
    python3 "$pre" 2>&1 | tee "$pre_log"
    fail_on_logged_skip "$pre_log" "$pre"
done
printf '[spm] swift test (RawLabKitTests)\n'
spm_log="$MODEL_CACHE/swift-test.log"
swift test --package-path "$ROOT" --scratch-path "$SWIFTPM_TEST_SCRATCH" 2>&1 | tee "$spm_log"
fail_on_logged_skip "$spm_log" "swift test"

if [[ -f "$ROOT/scripts/ci/swiftpm-rawlabkit.sh" ]]; then
    printf '[spm] prewarm RawLabNative/RawLabKit (%s)\n' "$1"
    source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
    rawlabnative_flags link "$RAWLAB_SWIFTPM_CACHE" macos 0 all
    if [[ "$1" == ios ]]; then
        rawlabkit_flags link "$RAWLAB_SWIFTPM_CACHE" iphonesimulator 0
    fi
    export RAWLAB_SWIFTPM_PREBUILT_MACOS=1
    export RAWLAB_SWIFTPM_PREBUILT=1
fi

max_jobs="${RAWLAB_APPLE_MODELS_JOBS:-4}"
case "$max_jobs" in
    ''|*[!0-9]*) max_jobs=4 ;;
esac
if [ "$max_jobs" -lt 1 ]; then
    max_jobs=1
fi

mkdir -p "$MODEL_CACHE/logs" "$MODEL_CACHE/work"
fail_rc=0
skip_fail=0

launch_suite() {
    local idx="$1"
    local suite="${suites[$idx]}"
    local suite_log="$MODEL_CACHE/logs/$idx.log"
    local suite_tmp="$MODEL_CACHE/work/$idx"
    mkdir -p "$suite_tmp"
    : > "$suite_log"
    (
        export TMPDIR="$suite_tmp"
        export RAWLAB_TEST_TMP_DIR="$suite_tmp"
        exec bash "$suite" > "$suite_log" 2>&1
    ) &
    pids+=("$!")
    idxs+=("$idx")
}

reap_finished() {
    local block="${1:-0}"
    while [ "${#pids[@]}" -gt 0 ]; do
        local reaped=0
        local next_pids=()
        local next_idxs=()
        local i
        for (( i = 0; i < ${#pids[@]}; i++ )); do
            local pid="${pids[$i]}"
            local idx="${idxs[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                local rc=0
                wait "$pid" || rc=$?
                local suite="${suites[$idx]}"
                local suite_log="$MODEL_CACHE/logs/$idx.log"
                printf '[model] %s\n' "$suite"
                if [[ -f "$suite_log" ]]; then
                    cat "$suite_log"
                fi
                if ! fail_on_logged_skip "$suite_log" "$suite"; then
                    skip_fail=1
                fi
                if [ "$rc" -ne 0 ]; then
                    printf 'error: %s failed with exit code %s\n' "$suite" "$rc" >&2
                    failed_suites+=("$suite (exit $rc)")
                    if [ "$fail_rc" -eq 0 ]; then
                        fail_rc="$rc"
                    fi
                fi
                reaped=1
            else
                next_pids+=("$pid")
                next_idxs+=("$idx")
            fi
        done
        pids=(${next_pids[@]+"${next_pids[@]}"})
        idxs=(${next_idxs[@]+"${next_idxs[@]}"})
        if [ "$block" -eq 0 ] || [ "$reaped" -eq 1 ]; then
            break
        fi
        sleep 0.05
    done
}

idx=0
total="${#suites[@]}"
while [ "$idx" -lt "$total" ]; do
    while [ "${#pids[@]}" -ge "$max_jobs" ]; do
        reap_finished 1
    done
    if [ "$fail_rc" -ne 0 ] || [ "$skip_fail" -ne 0 ]; then
        break
    fi
    launch_suite "$idx"
    idx=$((idx + 1))
    reap_finished 0
done

while [ "${#pids[@]}" -gt 0 ]; do
    reap_finished 1
done

if [ "${#failed_suites[@]}" -gt 0 ]; then
    printf 'error: apple models (%s): %d failure(s); suites queued after the first failure were not started\n' "$1" "${#failed_suites[@]}" >&2
    for failed in "${failed_suites[@]}"; do
        printf 'error:   %s\n' "$failed" >&2
    done
fi
if [ "$skip_fail" -ne 0 ]; then
    exit 1
fi
if [ "$fail_rc" -ne 0 ]; then
    exit "$fail_rc"
fi
