#!/bin/bash
set -euo pipefail
# 显式设备和独立 invocation，失败后也先 force-stop，再用新进程清理。
OUT="${1:?Pass an artifact directory}"
shift
DEVICE="${ANDROID_SERIAL:?Set the task-owned device serial}"
PORT="${ANDROID_ADB_SERVER_PORT:?Set the task-owned ADB server port}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
mkdir -p "$OUT"
if [ "$#" -eq 0 ]; then
    set -- disabledNewBatchValidatesImportedTargetWithCpu \
        resumedBatchWithGpuDisabledUsesCpuForPreviewAndOriginalSizeCleanExport \
        enabledNewAndResumedBatchesUseGlesInsteadOfBeingPinnedToCpu \
        enabledNewAndResumedBatchesFallBackForCpuOnlyRlookWhileForceExportFails
fi
adb_task() { "$ADB" -P "$PORT" -s "$DEVICE" "$@"; }
stop_app() {
    adb_task shell am force-stop com.rawlab.android
    if [ -n "$(adb_task shell pidof com.rawlab.android | tr -d '\r')" ]; then
        echo "Target process still alive; refusing cleanup" >&2
        exit 1
    fi
}
trap stop_app EXIT
failed=0
for method in "$@"; do
    stop_app
    adb_task shell am instrument -w -e class "com.rawlab.android.BatchGpuModeInstrumentedTest#$method" \
        -e batchAbortProbe "${BATCH_ABORT_PROBE:-false}" \
        -e batchLookAbortProbe "${BATCH_LOOK_ABORT_PROBE:-false}" \
        com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner | tee "$OUT/$method.log" || failed=1
    if ! rg -q '^OK \(1 test\)' "$OUT/$method.log" ||
        rg -q 'FAILURES|Process crashed|INSTRUMENTATION_FAILED|cleanupDeferred=true' "$OUT/$method.log"; then failed=1; fi
    stop_app
    adb_task shell am instrument -w -e class com.rawlab.android.BatchTestCleanupInstrumentedTest#recoversOnlyAfterPreviousOwnerProcessExited \
        com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner | tee "$OUT/$method-cleanup.log"
    rg -q '^OK \(1 test\)' "$OUT/$method-cleanup.log"
done
exit "$failed"
