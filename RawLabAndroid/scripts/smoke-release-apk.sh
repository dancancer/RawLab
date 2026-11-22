#!/usr/bin/env bash
# ============================================================================
#  Verify an Android release APK by performing clean cold starts on an emulator.
#  Refuses physical devices by default to avoid uninstalling user installs/data.
# ============================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: smoke-release-apk.sh <signed-release.apk> [options]

Options:
  --serial <emulator-serial>   Use an already running emulator (must match ^emulator-[0-9]+$)
  --avd <avd-name>             Boot a temporary headless AVD for this smoke run and stop it on exit
  --adb-port <port>            ADB server port (default: $ANDROID_ADB_SERVER_PORT or 5037)
  --launches <n>               Number of consecutive cold starts (default: 2)
  --settle-seconds <n>         Seconds to keep polling live PID after each launch (default: 8)
  --gpu <mode>                 Emulator -gpu mode when booting --avd (default: swiftshader_indirect)
  --package <id>               Application ID (default: com.rawlab.android)
  --activity <component>       Launch activity relative/full name (default: .MainActivity)
  --log-dir <dir>              Keep smoke logs in <dir> instead of a temporary directory
  --adb <path>                 Override adb executable path
  --apksigner <path>           Override apksigner executable path
  --emulator <path>            Override emulator executable path
  -h, --help                   Show this help message
EOF
}

APK=""
SERIAL=""
AVD=""
ADB_PORT="${ANDROID_ADB_SERVER_PORT:-5037}"
LAUNCHES=2
SETTLE_SECONDS=8
GPU="swiftshader_indirect"
PACKAGE="com.rawlab.android"
ACTIVITY=".MainActivity"
LOG_DIR=""
CLEANUP_LOG_DIR=false
ADB_BIN=""
APKSIGNER_BIN=""
EMULATOR_BIN=""
OWNED_EMU_PID=""

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --serial)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      SERIAL="$2"
      shift 2
      ;;
    --avd)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      AVD="$2"
      shift 2
      ;;
    --adb-port)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      ADB_PORT="$2"
      shift 2
      ;;
    --launches)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      LAUNCHES="$2"
      shift 2
      ;;
    --settle-seconds)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      SETTLE_SECONDS="$2"
      shift 2
      ;;
    --gpu)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      GPU="$2"
      shift 2
      ;;
    --package)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      PACKAGE="$2"
      shift 2
      ;;
    --activity)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      ACTIVITY="$2"
      shift 2
      ;;
    --log-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      LOG_DIR="$2"
      shift 2
      ;;
    --adb)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      ADB_BIN="$2"
      shift 2
      ;;
    --apksigner)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      APKSIGNER_BIN="$2"
      shift 2
      ;;
    --emulator)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      EMULATOR_BIN="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$APK" ]]; then
        APK="$1"
        shift
      else
        printf 'Unexpected argument: %s\n' "$1" >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "$APK" ]] || { usage >&2; exit 2; }
[[ -r "$APK" ]] || { printf 'Release APK is missing or unreadable: %s\n' "$APK" >&2; exit 2; }
[[ "$LAUNCHES" =~ ^[1-9][0-9]*$ ]] || { printf '--launches must be >= 1, got: %s\n' "$LAUNCHES" >&2; exit 2; }
[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || { printf '--settle-seconds must be >= 0, got: %s\n' "$SETTLE_SECONDS" >&2; exit 2; }
[[ "$ADB_PORT" =~ ^[1-9][0-9]*$ ]] || { printf '--adb-port must be a positive integer, got: %s\n' "$ADB_PORT" >&2; exit 2; }

if [[ -n "$SERIAL" && -n "$AVD" ]]; then
  echo "Specify either --serial or --avd, not both." >&2
  exit 2
fi

if [[ -n "$SERIAL" && ! "$SERIAL" =~ ^emulator-[0-9]+$ ]]; then
  printf 'Refusing non-emulator serial %s: release smoke uninstalls %s and only runs on emulators.\n' "$SERIAL" "$PACKAGE" >&2
  exit 2
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

if [[ -z "$ADB_BIN" ]]; then
  if [[ -n "$SDK" && -x "$SDK/platform-tools/adb" ]]; then
    ADB_BIN="$SDK/platform-tools/adb"
  elif command -v adb >/dev/null 2>&1; then
    ADB_BIN="$(command -v adb)"
  else
    echo "adb not found; set ANDROID_HOME or pass --adb." >&2
    exit 2
  fi
fi

if [[ -z "$APKSIGNER_BIN" ]]; then
  if [[ -n "$SDK" && -x "$SDK/build-tools/35.0.0/apksigner" ]]; then
    APKSIGNER_BIN="$SDK/build-tools/35.0.0/apksigner"
  elif command -v apksigner >/dev/null 2>&1; then
    APKSIGNER_BIN="$(command -v apksigner)"
  fi
fi

if [[ -z "$EMULATOR_BIN" ]]; then
  if [[ -n "$SDK" && -x "$SDK/emulator/emulator" ]]; then
    EMULATOR_BIN="$SDK/emulator/emulator"
  elif command -v emulator >/dev/null 2>&1; then
    EMULATOR_BIN="$(command -v emulator)"
  fi
fi

if [[ -n "$APKSIGNER_BIN" ]]; then
  "$APKSIGNER_BIN" verify --print-certs "$APK" >/dev/null
fi

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-android-smoke.XXXXXX")"
  CLEANUP_LOG_DIR=true
else
  mkdir -p "$LOG_DIR"
fi

ADB_CMD=("$ADB_BIN" -P "$ADB_PORT")

cleanup() {
  local status=$?
  if [[ -n "$OWNED_EMU_PID" ]]; then
    if kill -0 "$OWNED_EMU_PID" 2>/dev/null; then
      if [[ -n "$SERIAL" ]]; then
        "${ADB_CMD[@]}" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
      fi
      local wait_end=$((SECONDS + 20))
      while kill -0 "$OWNED_EMU_PID" 2>/dev/null && (( SECONDS < wait_end )); do
        sleep 1
      done
      if kill -0 "$OWNED_EMU_PID" 2>/dev/null; then
        kill "$OWNED_EMU_PID" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL "$OWNED_EMU_PID" >/dev/null 2>&1 || true
      fi
    fi
    wait "$OWNED_EMU_PID" 2>/dev/null || true
  fi
  if [[ "$CLEANUP_LOG_DIR" == true && -d "$LOG_DIR" ]]; then
    rm -rf "$LOG_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

find_free_emulator_port() {
  local devices_out
  devices_out="$("${ADB_CMD[@]}" devices 2>/dev/null || true)"
  python3 - "$devices_out" <<'PY'
import socket
import sys

devices = sys.argv[1]
active = set()
for line in devices.splitlines():
    parts = line.split()
    if parts and parts[0].startswith("emulator-"):
        active.add(parts[0])

def port_busy(port: int) -> bool:
    for host in ("127.0.0.1", "::1"):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:
                s.settimeout(0.1)
                if s.connect_ex((host, port)) == 0:
                    return True
        except OSError:
            pass
    return False

for port in range(5554, 5622, 2):
    if f"emulator-{port}" in active:
        continue
    if port_busy(port) or port_busy(port + 1):
        continue
    print(port)
    sys.exit(0)
sys.exit(1)
PY
}

inspect_logs_for_crash() {
  local crash_log="$1"
  local main_log="$2"
  local pkg="$3"
  local known_pid="$4"
  python3 - "$crash_log" "$main_log" "$pkg" "$known_pid" <<'PY'
import re
import sys
from pathlib import Path

crash_text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
main_text = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
pkg = sys.argv[3]
known_pid = sys.argv[4].strip()

crash_fatal_re = re.compile(r"FATAL EXCEPTION|Fatal signal|SIGABRT|SIGSEGV|SIGBUS|SIGILL|Abort message:")
foreign_proc_re = re.compile(r"(?:Process:\s*|>>>\s*)([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)")

if crash_fatal_re.search(crash_text) or f"Process: {pkg}" in crash_text or f">>> {pkg} <<<" in crash_text:
    mentioned_pkgs = set(foreign_proc_re.findall(crash_text))
    if not mentioned_pkgs or pkg in mentioned_pkgs:
        sys.stderr.write(f"Detected crash buffer entry for {pkg}:\n")
        for line in crash_text.splitlines()[:40]:
            sys.stderr.write(f"  {line}\n")
        sys.exit(1)

pids = {known_pid} if known_pid.isdigit() else set()
for m in re.finditer(rf"Start proc\s+(\d+):{re.escape(pkg)}\b|Process:\s*{re.escape(pkg)},\s*PID:\s*(\d+)", main_text):
    for g in m.groups():
        if g:
            pids.add(g)

main_fatal_re = re.compile(
    r"FATAL EXCEPTION|Fatal signal|SIGABRT|SIGSEGV|SIGBUS|SIGILL|"
    r"ClassNotFoundException|NoClassDefFoundError|NoSuchMethodError|NoSuchFieldError|"
    r"UnsatisfiedLinkError|JNI DETECTED ERROR|Abort message:|"
    rf"ANR in\s+{re.escape(pkg)}\b"
)
pid_token_re = re.compile(r"(?:\(\s*|\s)(\d{2,7})(?:\s*\)|\s+)")

hits = []
for line in main_text.splitlines():
    if not main_fatal_re.search(line):
        continue
    if pkg in line:
        hits.append(line)
        continue
    if pids:
        line_pids = set(pid_token_re.findall(line))
        if line_pids & pids:
            hits.append(line)

if hits:
    sys.stderr.write(f"Detected fatal runtime error for {pkg} in logcat:\n")
    for line in hits[:30]:
        sys.stderr.write(f"  {line}\n")
    sys.exit(1)
PY
}

if [[ -n "$AVD" ]]; then
  [[ -n "$EMULATOR_BIN" && -x "$EMULATOR_BIN" ]] || {
    echo "emulator binary not found; set ANDROID_HOME or pass --emulator." >&2
    exit 2
  }
  "${ADB_CMD[@]}" start-server >/dev/null 2>&1 || true
  EMU_PORT="$(find_free_emulator_port)" || {
    echo "Failed to find a free emulator port in 5554..5620." >&2
    exit 1
  }
  SERIAL="emulator-$EMU_PORT"
  "$EMULATOR_BIN" -avd "$AVD" -port "$EMU_PORT" \
    -no-snapshot -no-window -no-audio -no-boot-anim -gpu "$GPU" \
    >"$LOG_DIR/emulator.log" 2>&1 &
  OWNED_EMU_PID=$!

  boot_deadline=$((SECONDS + 180))
  while true; do
    if ! kill -0 "$OWNED_EMU_PID" 2>/dev/null; then
      printf 'Owned emulator (PID %s, %s) exited before completing boot:\n' "$OWNED_EMU_PID" "$AVD" >&2
      tail -n 30 "$LOG_DIR/emulator.log" >&2 || true
      exit 1
    fi
    state="$("${ADB_CMD[@]}" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ "$state" == "device" ]]; then
      booted="$("${ADB_CMD[@]}" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
      if [[ "$booted" == "1" ]] && "${ADB_CMD[@]}" -s "$SERIAL" shell pm path android >/dev/null 2>&1; then
        break
      fi
    fi
    if (( SECONDS >= boot_deadline )); then
      printf 'Timed out waiting for %s (%s) to finish booting.\n' "$SERIAL" "$AVD" >&2
      tail -n 30 "$LOG_DIR/emulator.log" >&2 || true
      exit 1
    fi
    sleep 2
  done
elif [[ -z "$SERIAL" ]]; then
  mapfile_emulators=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^(emulator-[0-9]+)[[:space:]]+device$ ]]; then
      mapfile_emulators+=("${BASH_REMATCH[1]}")
    fi
  done < <("${ADB_CMD[@]}" devices 2>/dev/null || true)

  if (( ${#mapfile_emulators[@]} == 1 )); then
    SERIAL="${mapfile_emulators[0]}"
  elif (( ${#mapfile_emulators[@]} == 0 )); then
    echo "No online emulator found on ADB port $ADB_PORT; pass --serial emulator-XXXX or --avd <avd-name>." >&2
    if [[ -n "$EMULATOR_BIN" && -x "$EMULATOR_BIN" ]]; then
      echo "Available AVDs:" >&2
      "$EMULATOR_BIN" -list-avds >&2 || true
    fi
    exit 2
  else
    printf 'Multiple online emulators found (%s); pass --serial explicitly.\n' "${mapfile_emulators[*]}" >&2
    exit 2
  fi
fi

# Clean install ensures APK signature changes or stale install state cannot mask startup bugs.
"${ADB_CMD[@]}" -s "$SERIAL" uninstall "$PACKAGE" >/dev/null 2>&1 || true
"${ADB_CMD[@]}" -s "$SERIAL" install -r "$APK" >/dev/null

for ((launch = 1; launch <= LAUNCHES; launch++)); do
  "${ADB_CMD[@]}" -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  stop_deadline=$((SECONDS + 5))
  while true; do
    pid_check="$("${ADB_CMD[@]}" -s "$SERIAL" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r\n ' || true)"
    [[ -z "$pid_check" ]] && break
    if (( SECONDS >= stop_deadline )); then
      printf 'Existing %s process (%s) did not stop before launch %s.\n' "$PACKAGE" "$pid_check" "$launch" >&2
      exit 1
    fi
    sleep 1
  done

  "${ADB_CMD[@]}" -s "$SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  "${ADB_CMD[@]}" -s "$SERIAL" logcat -b all -c >/dev/null 2>&1 || true

  start_log="$LOG_DIR/start-$launch.log"
  if ! "${ADB_CMD[@]}" -s "$SERIAL" shell am start -W -S -n "$PACKAGE/$ACTIVITY" >"$start_log" 2>&1; then
    printf 'am start failed on launch %s:\n' "$launch" >&2
    cat "$start_log" >&2 || true
    exit 1
  fi
  if ! grep -q "Status: ok" "$start_log" || grep -q "^Error:" "$start_log"; then
    printf 'Unexpected am start output on launch %s:\n' "$launch" >&2
    cat "$start_log" >&2 || true
    exit 1
  fi

  live_pid=""
  if (( SETTLE_SECONDS == 0 )); then
    raw_pid="$("${ADB_CMD[@]}" -s "$SERIAL" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r\n' || true)"
    live_pid="${raw_pid%% *}"
    if [[ -z "$live_pid" ]]; then
      "${ADB_CMD[@]}" -s "$SERIAL" logcat -d -b crash >"$LOG_DIR/crash-$launch.log" 2>&1 || true
      "${ADB_CMD[@]}" -s "$SERIAL" logcat -d >"$LOG_DIR/logcat-$launch.log" 2>&1 || true
      inspect_logs_for_crash "$LOG_DIR/crash-$launch.log" "$LOG_DIR/logcat-$launch.log" "$PACKAGE" "" || true
      printf 'Process %s exited immediately after launch %s.\n' "$PACKAGE" "$launch" >&2
      exit 1
    fi
  else
    for ((sec = 1; sec <= SETTLE_SECONDS; sec++)); do
      sleep 1
      raw_pid="$("${ADB_CMD[@]}" -s "$SERIAL" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r\n' || true)"
      live_pid="${raw_pid%% *}"
      if [[ -z "$live_pid" ]]; then
        "${ADB_CMD[@]}" -s "$SERIAL" logcat -d -b crash >"$LOG_DIR/crash-$launch.log" 2>&1 || true
        "${ADB_CMD[@]}" -s "$SERIAL" logcat -d >"$LOG_DIR/logcat-$launch.log" 2>&1 || true
        inspect_logs_for_crash "$LOG_DIR/crash-$launch.log" "$LOG_DIR/logcat-$launch.log" "$PACKAGE" "" || true
        printf 'Process %s disappeared during settle (%ss/%ss) on launch %s.\n' "$PACKAGE" "$sec" "$SETTLE_SECONDS" "$launch" >&2
        exit 1
      fi
    done
  fi

  crash_log="$LOG_DIR/crash-$launch.log"
  main_log="$LOG_DIR/logcat-$launch.log"
  "${ADB_CMD[@]}" -s "$SERIAL" logcat -d -b crash >"$crash_log" 2>&1 || true
  "${ADB_CMD[@]}" -s "$SERIAL" logcat -d >"$main_log" 2>&1 || true
  inspect_logs_for_crash "$crash_log" "$main_log" "$PACKAGE" "$live_pid"
done

"${ADB_CMD[@]}" -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
printf 'PASS: Release APK cold-start smoke passed (%s/%s launches, package=%s, serial=%s)\n' \
  "$LAUNCHES" "$LAUNCHES" "$PACKAGE" "$SERIAL"
