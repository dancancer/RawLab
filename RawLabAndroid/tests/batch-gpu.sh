#!/bin/bash
set -euo pipefail
# 显式设备和独立 invocation，失败后也先 force-stop，再用新进程清理。
OUT="${1:?Pass an artifact directory}"
shift
DEVICE="${ANDROID_SERIAL:?Set the task-owned device serial}"
PORT="${ANDROID_ADB_SERVER_PORT:?Set the task-owned ADB server port}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
APP_ID="${RAWLAB_TEST_APP_ID:-com.rawlab.android}"
if [[ ! "$APP_ID" =~ ^com\.rawlab\.android(\.[a-zA-Z][a-zA-Z0-9_]*)*$ ]]; then
    echo 'Invalid batch test application ID' >&2
    exit 1
fi
if [[ "$DEVICE" != emulator-* && "$APP_ID" == com.rawlab.android ]]; then
    echo 'Physical-device tests require an isolated RAWLAB_TEST_APP_ID' >&2
    exit 1
fi
mkdir -p "$OUT"
if [ "$#" -eq 0 ]; then
    set -- disabledNewBatchValidatesImportedTargetWithCpu \
        resumedBatchWithGpuDisabledUsesCpuForPreviewAndOriginalSizeCleanExport \
        enabledNewAndResumedBatchesUseGlesInsteadOfBeingPinnedToCpu \
        enabledNewAndResumedBatchesFallBackForCpuOnlyRlookWhileForceExportFails \
        'BatchWorkflowInstrumentedTest#remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords' \
        'BatchWorkflowInstrumentedTest#removesKnownPartialOutputBeforeResumingAndCanDiscardTheTask'
fi
adb_task() { "$ADB" -P "$PORT" -s "$DEVICE" "$@"; }
stop_app() {
    adb_task shell am force-stop "$APP_ID"
    if [ -n "$(adb_task shell pidof "$APP_ID" | tr -d '\r')" ]; then
        echo "Target process still alive; refusing cleanup" >&2
        exit 1
    fi
}
trap stop_app EXIT
failed=0
for method in "$@"; do
    stop_app
    case "$method" in
        com.rawlab.android.*'#'*) selector="$method" ;;
        *'#'*) selector="com.rawlab.android.$method" ;;
        *) selector="com.rawlab.android.BatchGpuModeInstrumentedTest#$method" ;;
    esac
    if [[ ! "$selector" =~ ^com\.rawlab\.android\.[a-zA-Z_][a-zA-Z0-9_]*#[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo 'Invalid batch test selector' >&2
        exit 1
    fi
    preview_probe=false
    natural_probe=false
    look_stage_probe=false
    partial_probe=none
    case "$selector" in
        com.rawlab.android.BatchWorkflowInstrumentedTest#remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords)
            preview_probe="${BATCH_PREVIEW_ABORT_PROBE:-false}"
            natural_probe="${BATCH_PREVIEW_NATURAL_TIMEOUT_PROBE:-false}" ;;
        com.rawlab.android.BatchGpuModeInstrumentedTest#enabledNewAndResumedBatchesFallBackForCpuOnlyRlookWhileForceExportFails)
            look_stage_probe="${BATCH_LOOK_STAGE_ABORT_PROBE:-false}" ;;
        com.rawlab.android.BatchWorkflowInstrumentedTest#removesKnownPartialOutputBeforeResumingAndCanDiscardTheTask)
            partial_probe="${BATCH_PARTIAL_ABORT_PROBE:-none}" ;;
    esac
    if [ "$preview_probe" = true ] && [ "$natural_probe" = true ]; then echo 'Choose one preview probe' >&2; exit 1; fi
    case "$partial_probe" in none|beforeCheckpoint|afterCheckpoint) ;; *) echo 'Invalid partial probe window' >&2; exit 1 ;; esac
    adb_task shell am instrument -w -e class "$selector" \
        -e batchAbortProbe "${BATCH_ABORT_PROBE:-false}" \
        -e batchLookAbortProbe "${BATCH_LOOK_ABORT_PROBE:-false}" \
        -e batchPreviewAbortProbe "$preview_probe" \
        -e batchPreviewNaturalTimeoutProbe "$natural_probe" \
        -e batchLookStageAbortProbe "$look_stage_probe" \
        -e batchPartialAbortProbe "$partial_probe" \
        "$APP_ID.test/androidx.test.runner.AndroidJUnitRunner" | tee "$OUT/$method.log" || failed=1
    if ! rg -q '^OK \(1 test\)' "$OUT/$method.log" ||
        rg -q 'FAILURES|Process crashed|INSTRUMENTATION_FAILED|cleanupDeferred=true' "$OUT/$method.log"; then failed=1; fi
    stop_app
    preview_recovery=false
    if [ "$preview_probe" = true ] || [ "$natural_probe" = true ]; then preview_recovery=true; fi
    adb_task shell am instrument -w -e class com.rawlab.android.BatchTestCleanupInstrumentedTest#recoversOnlyAfterPreviousOwnerProcessExited \
        -e batchPreviewRecoveryProbe "$preview_recovery" \
        -e batchLookStageRecoveryProbe "$look_stage_probe" \
        -e batchPartialRecoveryProbe "$partial_probe" \
        "$APP_ID.test/androidx.test.runner.AndroidJUnitRunner" | tee "$OUT/$method-cleanup.log"
    rg -q '^OK \(1 test\)' "$OUT/$method-cleanup.log"
    if [ "$preview_probe" = true ]; then
        rg -q 'Batch preview probe nativeProcessActive=true phase=SELECTING operation=NONE' "$OUT/$method.log"
    fi
    if [ "$natural_probe" = true ]; then
        rg -q 'Batch preview naturalTimeout=true .*exception=ComposeTimeoutException cpuExportNativeProcess=true previewNativeCreateBlocked=true phase=SELECTING operation=NONE' "$OUT/$method.log"
    fi
    if [ "$preview_recovery" = true ]; then
        rg -q 'cleanupDeferred=true' "$OUT/$method.log"
        rg -q 'Process crashed' "$OUT/$method.log"
        rg -q 'Batch preview recovery oldPid=.* inputsPreserved=true' "$OUT/$method-cleanup.log"
        rg -q 'cleanupComplete' "$OUT/$method-cleanup.log"
        echo 'Preview isolation verified; failed invocation remains failed.'
    fi
    if [ "$look_stage_probe" = true ]; then
        rg -q 'lookImportStage nativeValidated=true .*beforeCommit=true' "$OUT/$method.log"
        rg -q 'Process crashed' "$OUT/$method.log"
        rg -q 'Batch look recovery .*stagePreserved=true' "$OUT/$method-cleanup.log"
        rg -q 'cleanupComplete' "$OUT/$method-cleanup.log"
        echo 'Look import recovery verified; injected crash remains a failed test.'
    fi
    if [ "$partial_probe" != none ]; then
        rg -q "Batch partial abort window=$partial_probe" "$OUT/$method.log"
        rg -q 'Process crashed' "$OUT/$method.log"
        rg -q "Batch partial recovery window=$partial_probe .*pendingPreserved=true" "$OUT/$method-cleanup.log"
        rg -q 'cleanupComplete' "$OUT/$method-cleanup.log"
        echo 'Partial publication recovery verified; injected crash remains a failed test.'
    fi
done
exit "$failed"
