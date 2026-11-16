#!/usr/bin/env bash
# Seed the simulator fixtures the EditorUITests / EditorV4UITests suites expect:
#   - Photos library: the named DJI DNG (importPhoto taps it in the system picker)
#   - Files local storage Downloads: the same DNG (importRAWFile) plus a small
#     RawLabFilesFixture.png raster (EditorV4 testFilesPicker…)
# Prerequisite: the Files app must have opened at least once so the LocalStorage
# AppGroup exists; this script launches com.apple.DocumentsApp to materialize it.
# Usage: IOS_SIMULATOR_UDID=<udid> bash RawLab/tests/seed-sim-ui-fixtures.sh
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
udid="${IOS_SIMULATOR_UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
[ -n "$udid" ] || { echo "No booted simulator; pass IOS_SIMULATOR_UDID." >&2; exit 1; }
raw="${RAWLAB_TEST_RAW:-$repo_root/lutools/examples/DJI_20250602164503_0444_D.DNG}"
[ -f "$raw" ] || { echo "Missing RAW fixture: $raw" >&2; exit 1; }

# The Files picker needs the Files app to have materialized its local storage once.
python3 - "$udid" "$raw" <<'PY'
import plistlib, shutil, struct, subprocess, sys, time, uuid, zlib
from pathlib import Path

udid, raw = sys.argv[1], Path(sys.argv[2])

def local_storage_downloads():
    try:
        device_home = subprocess.check_output(
            ['xcrun', 'simctl', 'get_app_container', udid, 'com.apple.DocumentsApp', 'data'],
            text=True).strip()
    except subprocess.CalledProcessError:
        return None
    device_data = Path(device_home).parent.parent.parent  # .../Devices/<udid>/data
    groups = device_data / 'Containers/Shared/AppGroup'
    if not groups.is_dir():
        return None
    for group in sorted(groups.iterdir()):
        metadata = group / '.com.apple.containermanagerd.metadata.plist'
        if metadata.is_file():
            try:
                ident = plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier')
            except Exception:
                ident = None
            if ident == 'group.com.apple.FileProvider.LocalStorage':
                return group / 'File Provider Storage/Downloads'
    return None

downloads = local_storage_downloads()
if downloads is None:
    subprocess.run(['xcrun', 'simctl', 'launch', udid, 'com.apple.DocumentsApp'], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(10):
        time.sleep(3)
        downloads = local_storage_downloads()
        if downloads is not None:
            break
if downloads is None:
    # The local storage provider creates its container lazily on first document access;
    # opening Files once (or running any document-picker test) materializes it. Files-based
    # cases remain red until then - same precondition as editor-ui.sh.
    print('WARNING: Files local storage AppGroup not present yet; Files fixtures skipped. '
          'Open Files (or run a picker test) once and re-run this script.')
    raise SystemExit(0)
downloads.mkdir(parents=True, exist_ok=True)
shutil.copyfile(raw, downloads / raw.name)

# Minimal valid 2x2 PNG raster so the Files picker always finds the named fixture.
def chunk(tag, body):
    return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
rows = zlib.compress(b''.join(b'\x00' + bytes([80 + 40 * x, 120, 200 - 40 * x]) * 2 for _ in range(2)))
(downloads / 'RawLabFilesFixture.png').write_bytes(
    b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', rows) + chunk(b'IEND', b''))
print(f'Seeded Files Downloads: {downloads}')
PY

# Photos-library seed for the system picker (importPhoto ranks the named DNG first).
if [ "${RAWLAB_SKIP_PHOTOS_SEED:-0}" != "1" ]; then
    xcrun simctl addmedia "$udid" "$raw"
    echo "Seeded Photos library: $raw"
fi
