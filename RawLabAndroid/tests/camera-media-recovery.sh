#!/bin/bash
set -euo pipefail

OUT="${1:?Pass an artifact directory}"
DEVICE="${ANDROID_SERIAL:?Set the task-owned device serial}"
PORT="${ANDROID_ADB_SERVER_PORT:?Set the task-owned ADB server port}"
APP_ID="${RAWLAB_TEST_APP_ID:-com.rawlab.android}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
CLASS=com.rawlab.android.camera.CameraMediaRecoveryTest
MANIFEST=files/camera-media-recovery-test.json
if [[ ! "$APP_ID" =~ ^com\.rawlab\.android(\.[a-zA-Z][a-zA-Z0-9_]*)*$ ]]; then
    echo 'Invalid camera test application ID' >&2; exit 1
fi
if [[ "$DEVICE" != emulator-* && "$APP_ID" == com.rawlab.android ]]; then
    echo 'Physical-device tests require an isolated RAWLAB_TEST_APP_ID' >&2; exit 1
fi
mkdir -p "$OUT"
adb_task() { "$ADB" -P "$PORT" -s "$DEVICE" "$@"; }
assert_absent() {
    local state
    state="$(adb_task shell "$1" | tr -d '\r')" || return 1
    if [ "$state" != ABSENT ]; then
        echo "$2 (probe result: $state)" >&2; return 1
    fi
}
assert_no_manifest() {
    assert_absent "run-as $APP_ID sh -c 'if [ -e $MANIFEST ]; then echo PRESENT; else echo ABSENT; fi'" \
        'Recovery fixture exists or could not be checked; refusing to continue'
}
stop_app() {
    local pids
    adb_task shell am force-stop "$APP_ID"
    # pidof 的 1 表示不存在；其他失败和 ADB 断连必须保留为错误。
    pids="$(adb_task shell "pidof $APP_ID; code=\$?; [ \"\$code\" -eq 0 ] || [ \"\$code\" -eq 1 ]" | tr -d '\r')" || return 1
    if [ -n "$pids" ]; then
        echo 'Target process is still alive' >&2; return 1
    fi
}
run_phase() {
    adb_task shell am instrument -w -r -e class "$CLASS#$1" -e cameraRecoveryPhase "$2" \
        "$APP_ID.test/androidx.test.runner.AndroidJUnitRunner"
}
trap stop_app EXIT
adb_task shell run-as "$APP_ID" pwd >/dev/null
if [ "$(adb_task shell getprop ro.build.version.sdk | tr -d '\r')" -lt 29 ]; then
    echo 'Camera MediaStore recovery requires API 29+' >&2; exit 1
fi
for phase in pending published; do
    stop_app
    assert_no_manifest
    if [ "$phase" = pending ]; then stage=stagePendingBeforeProcessDeath; else stage=stagePublishedBeforeProcessDeath; fi
    # Android 的 am instrument 在目标进程退出时也可能返回 0；必须核对退出标记和落盘记录。
    run_phase "$stage" "stage-$phase" >"$OUT/$phase-stage.log" 2>&1 || true
    cat "$OUT/$phase-stage.log"
    rg -q 'INSTRUMENTATION_RESULT: shortMsg=Process crashed' "$OUT/$phase-stage.log"
    adb_task exec-out run-as "$APP_ID" cat "$MANIFEST" >"$OUT/$phase-manifest.json"
    old_pid="$(python3 - "$OUT/$phase-manifest.json" "$phase" <<'PY'
import json, re, sys
record = json.load(open(sys.argv[1]))
assert re.fullmatch(r'camera-media-recovery-[0-9a-f-]{36}', record['root'])
assert re.fullmatch(r'content://media/external_primary/images/media/[1-9][0-9]*', record['uri'])
assert re.fullmatch(r'[0-9a-f]{64}', record['digest'])
assert record['published'] == (sys.argv[2] == 'published')
assert isinstance(record['pid'], int) and record['pid'] > 0
print(record['pid'])
PY
)"
    assert_absent "if [ -d /proc/$old_pid ]; then echo PRESENT; else echo ABSENT; fi" \
        'The staged process did not exit or could not be checked'
    stop_app
    run_phase recoverInNewProcess recover >"$OUT/$phase-recover.log" 2>&1
    cat "$OUT/$phase-recover.log"
    rg -q '^OK \(1 test\)' "$OUT/$phase-recover.log"
    if rg -q 'FAILURES|Process crashed|INSTRUMENTATION_FAILED' "$OUT/$phase-recover.log"; then
        echo 'Recovery or fixture cleanup failed' >&2; exit 1
    fi
    assert_no_manifest
done
echo 'Both camera MediaStore process-death recovery scenarios passed.'
