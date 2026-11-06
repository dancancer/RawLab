#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Pass a fresh dedicated simulator UUID}"
PRODUCTS="${1:?Pass the current build-for-testing Build/Products directory}"
OUT="${2:?Pass a new output directory}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -e "$OUT" ]]; then echo "Output already exists: $OUT" >&2; exit 1; fi
mkdir -p "$OUT"
python3 - "$ROOT" "$PRODUCTS" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, os, plistlib, shutil, struct, subprocess, sys, zlib

root, products, out = (Path(x).resolve() for x in sys.argv[1:])
runs = list(products.glob('*.xctestrun'))
if len(runs) != 1:
    raise SystemExit('Expected one RawLab xctestrun')
def resolve(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', str(products))
    if isinstance(value, list): return [resolve(x) for x in value]
    if isinstance(value, dict): return {k: resolve(v) for k, v in value.items()}
    return value
config = resolve(plistlib.loads(runs[0].read_bytes()))
targets = [t for c in config.get('TestConfigurations', []) for t in c['TestTargets']]
if not targets:
    targets = [v for k, v in config.items() if not k.startswith('__') and isinstance(v, dict)]
for target in targets:
    target.setdefault('EnvironmentVariables', {})['RAWLAB_DOCUMENT_IMPORT_UI'] = '1'
    if 'UITargetAppPath' not in target: continue
    original = target['UITargetAppPath']
    original_runner = target['TestHostPath']
    runner = out / 'RawLabUITests-Runner.app'
    shutil.copytree(original_runner, runner)
    test_bundle = runner / 'PlugIns/RawLabUITests.xctest'
    target['TestHostPath'] = str(runner)
    target['TestBundlePath'] = str(test_bundle)
    app = out / 'RawLabImportUI.app'
    shutil.copytree(original, app)
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    # 只在测试副本开启文件共享，供真实 Files 窗口读取生成的测试文件。
    info.update(UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    device = os.environ['IOS_SIMULATOR_UDID']
    # 专用模拟器每轮重装 app 和 runner，避免保留上一轮已加载的测试代码与外观库。
    for bundle_id in [target['TestHostBundleIdentifier'], info['CFBundleIdentifier']]:
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle_id],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['xcrun', 'simctl', 'uninstall', device, bundle_id],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'install', device, str(app)], check=True)
    data = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device,
                                       info['CFBundleIdentifier'], 'data'], text=True).strip())
    documents = data / 'Documents'
    documents.mkdir(exist_ok=True)
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)
    width, height = 320, 240
    pixels = b''.join(b'\0' + b''.join(bytes((x % 256, y % 256, (x + y) % 256))
                                     for x in range(width)) for y in range(height))
    (documents / 'RawLabImportFixture.png').write_bytes(
        b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
    if os.environ.get('RAWLAB_DOCUMENT_IMPORT_TEST', '').endswith('/testIPadJPEGPreviewResolvesFineDetailAfterZoom'):
        width, height = 7008, 4672
        stripes = (b'\x18' * 9 + b'\xe8' * 9) * (width // 6)
        encoder = zlib.compressobj()
        pixels = b''.join(encoder.compress(b'\0' + stripes) for _ in range(height)) + encoder.flush()
        chart = out / 'detail.png'
        chart.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                          + chunk(b'IDAT', pixels) + chunk(b'IEND', b''))
        subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', 'best', str(chart),
                        '--out', str(documents / 'RawLabDetailFixture.jpeg')], check=True, stdout=subprocess.DEVNULL)
        chart.unlink()
    values = '\n'.join(f'{i & 1} {(i >> 1) & 1} {(i >> 2) & 1}' for i in range(8)) + '\n'
    (documents / 'RawLabImportFixture.cube').write_text(
        '#Gamma:F-Log2 to Test\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\n' + values)
    (documents / 'RawLabUnknownLook.cube').write_text('LUT_3D_SIZE 2\n' + values)
    target['UITargetAppPath'] = str(app)
    target['DependentProductPaths'] = [str(app), str(runner), str(test_bundle)]
    source_files = ['RawLab/RawLab/UI/Editor/ContentView.swift',
                    'RawLab/RawLab/UI/Editor/ContentView+Helpers.swift',
                    'RawLab/RawLab/UI/Editor/ContentView+Panels.swift',
                    'RawLab/RawLabUITests/DocumentImportUITests.swift']
    binaries = [info['CFBundleExecutable'], 'RawLab.debug.dylib', 'Frameworks/sony2fuji.framework/sony2fuji']
    (out / 'source-receipt.json').write_text(json.dumps({
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'diff': subprocess.check_output(['git', 'diff', '--', 'RawLab'], cwd=root, text=True),
        'sourceSHA256': {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in source_files},
        'appBinarySHA256': {p: hashlib.sha256((app / p).read_bytes()).hexdigest()
                            for p in binaries if (app / p).is_file()},
        'testBinarySHA256': hashlib.sha256((test_bundle / 'RawLabUITests').read_bytes()).hexdigest(),
        'testHostBundleIdentifier': target['TestHostBundleIdentifier'],
        'device': device,
        'scope': 'Real app and native framework; only test-copy Info.plist enables Files sharing'
    }, indent=2) + '\n')
plistlib.dump(config, (out / 'document-import.xctestrun').open('wb'))
PY
STATUS=0
TEST_FILTERS=(-only-testing:"${RAWLAB_DOCUMENT_IMPORT_TEST:-RawLabUITests/DocumentImportUITests}")
# The large-photo detail check requires an iPad and its own fixture; select it explicitly.
if [[ "${RAWLAB_DOCUMENT_IMPORT_TEST:-}" != */testIPadJPEGPreviewResolvesFineDetailAfterZoom ]]; then
    TEST_FILTERS+=(-skip-testing:RawLabUITests/DocumentImportUITests/testIPadJPEGPreviewResolvesFineDetailAfterZoom)
fi
xcodebuild test-without-building -xctestrun "$OUT/document-import.xctestrun" \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -resultBundlePath "$OUT/DocumentImport.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    "${TEST_FILTERS[@]}" \
    > "$OUT/document-import-ui.log" 2>&1 || STATUS=$?
xcrun xcresulttool get test-results summary --path "$OUT/DocumentImport.xcresult" --compact > "$OUT/summary.json"
python3 - "$OUT" <<'PY'
import hashlib, json, os, pathlib, plistlib, subprocess, sys
out = pathlib.Path(sys.argv[1])
receipt = json.loads((out / 'source-receipt.json').read_text())
info = plistlib.loads((out / 'RawLabImportUI.app/Info.plist').read_bytes())
installed = pathlib.Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
    os.environ['IOS_SIMULATOR_UDID'], info['CFBundleIdentifier'], 'app'], text=True).strip())
receipt['installedBinarySHA256'] = {p: hashlib.sha256((installed / p).read_bytes()).hexdigest()
                                  for p in receipt['appBinarySHA256']}
assert receipt['appBinarySHA256'] == receipt['installedBinarySHA256'], 'Installed app does not match the test app'
runner = pathlib.Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
    os.environ['IOS_SIMULATOR_UDID'], receipt['testHostBundleIdentifier'], 'app'], text=True).strip())
receipt['installedTestBinarySHA256'] = hashlib.sha256(
    (runner / 'PlugIns/RawLabUITests.xctest/RawLabUITests').read_bytes()).hexdigest()
assert receipt['testBinarySHA256'] == receipt['installedTestBinarySHA256'], 'Installed UI tests do not match the built tests'
(out / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
if [[ "$STATUS" -ne 0 ]]; then exit "$STATUS"; fi
python3 - "$OUT/summary.json" <<'PY'
import json, os, sys
result = json.load(open(sys.argv[1]))
assert result['failedTests'] == 0 and result['passedTests'] > 0 and result['skippedTests'] == 0, result
if not os.environ.get('RAWLAB_DOCUMENT_IMPORT_TEST'):
    assert result['passedTests'] == result['totalTestCount'] == 4, result
PY
echo "PASS: document import UI; results: $OUT/DocumentImport.xcresult"
