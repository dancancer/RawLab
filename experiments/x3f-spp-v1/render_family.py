"""固定原生设置的分代显影对照；不会套用 DP1S 拟合模型或自动回退。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import numpy as np

from scene_cache import DECODER_REVISION, digest
from family_contract import validate as validate_contract

PIPELINES = ('native', 'as-shot', 'merrill-spp')
SETTINGS_POLICY = 'fixed-native-settings-not-saved-adjustments'


def validate_protocol(protocol, source, pipeline):
    expected = {
        'schema': 'rawlab-family-render-v1', 'decoder_revision': DECODER_REVISION,
        'source_path': str(Path(source).resolve()), 'pipeline': pipeline,
        'color_encoding': 'sRGB', 'denoise_backend': 'cpu', 'denoise_intensity': 10,
        'spp_denoise': pipeline == 'merrill-spp',
        'camera_mode': None if pipeline == 'native' else 'as-shot',
        'environment_policy': 'x3f-tunables-cleared',
        'settings_policy': SETTINGS_POLICY,
    }
    if pipeline not in PIPELINES or any(protocol.get(key) != value for key, value in expected.items()):
        raise ValueError('Native renderer source, version or processing settings do not match')
    if type(protocol.get('header_version')) is not int or protocol['header_version'] <= 0:
        raise ValueError('Missing native X3F version')


def oriented_pixels(pixels, orientation):
    if orientation == 1:
        return pixels
    if orientation == 2:
        return pixels[:, ::-1]
    if orientation == 3:
        return pixels[::-1, ::-1]
    if orientation == 4:
        return pixels[::-1]
    if orientation == 5:
        return pixels.transpose(1, 0, 2)
    if orientation == 6:
        return np.rot90(pixels, -1)
    if orientation == 7:
        return pixels.transpose(1, 0, 2)[::-1, ::-1]
    if orientation == 8:
        return np.rot90(pixels, 1)
    raise ValueError('Invalid native TIFF orientation')


def publish_output(native_tiff, output, evidence):
    import tifffile

    output = Path(output)
    report_path = Path(str(output) + '.json')
    if output.exists() or report_path.exists():
        raise FileExistsError('Output image or evidence already exists')
    with tifffile.TiffFile(native_tiff) as tif:
        if len(tif.pages) != 1:
            raise ValueError('Expected one native TIFF image')
        page = tif.pages[0]
        if page.dtype != np.uint16 or len(page.shape) != 3 or page.shape[-1] != 3:
            raise ValueError('Native output must contain uint16 RGB pixels')
        profile_tag = page.tags.get(34675)
        icc = profile_tag.value if profile_tag is not None else b''
        if len(icc) < 128 or icc[16:20] != b'RGB ' or icc[36:40] != b'acsp':
            raise ValueError('Native output must carry an RGB ICC profile')
        orientation_tag = page.tags.get('Orientation')
        orientation = int(orientation_tag.value) if orientation_tag is not None else 1
        pixels = oriented_pixels(page.asarray(), orientation)
    output.parent.mkdir(parents=True, exist_ok=True)
    # 只归一化方向和 DPI；保留原生整数像素及 ICC，不再次应用显影或颜色曲线。
    with tempfile.TemporaryDirectory(prefix='.rawlab-family-', dir=output.parent) as work:
        staged_image, staged_report = Path(work) / 'image.tif', Path(work) / 'evidence.json'
        tifffile.imwrite(staged_image, pixels, photometric='rgb', metadata=None,
                         resolution=(180, 180), resolutionunit='INCH',
                         software='RawLab X3F native family experiment',
                         extratags=[(34675, 'B', len(icc), icc, False)])
        report = {**evidence, 'shape': list(pixels.shape), 'native_orientation': orientation,
                  'icc_sha256': hashlib.sha256(icc).hexdigest(),
                  'native_tiff_sha256': digest(native_tiff), 'output_sha256': digest(staged_image)}
        staged_report.write_text(json.dumps(report, indent=2) + '\n')
        linked = []
        try:
            for source, target in ((staged_image, output), (staged_report, report_path)):
                os.link(source, target)
                linked.append((source, target))
        except OSError:
            for source, target in linked:
                if target.exists() and os.path.samefile(source, target):
                    target.unlink()
            raise
    return report


def run_decoder(decoder, raw, native, pipeline):
    before, executable = digest(raw), digest(decoder)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('X3F_')}
    ignored = sorted(set(os.environ) - set(environment))
    try:
        result = subprocess.run([str(decoder), pipeline, str(raw), str(native)],
                                capture_output=True, text=True, env=environment)
    finally:
        # 错误退出、坏协议、甚至输出文本解码失败，都必须先检查输入完整性。
        for path, expected, label in ((raw, before, 'RAW'), (decoder, executable, 'Decoder')):
            try:
                unchanged = digest(path) == expected
            except OSError:
                unchanged = False
            if not unchanged:
                raise ValueError(f'{label} changed during rendering')
    if result.returncode:
        raise RuntimeError(f'Native pipeline failed without fallback: {result.stderr.strip()}')
    return result, before, executable, ignored


def render(decoder, raw, output, pipeline, contract):
    decoder, raw, output = Path(decoder).resolve(), Path(raw).resolve(), Path(output)
    if pipeline not in PIPELINES:
        raise ValueError('Unknown native pipeline')
    if output.exists() or Path(str(output) + '.json').exists():
        raise FileExistsError('Output image or evidence already exists')
    validate_contract(contract, decoder)
    with tempfile.TemporaryDirectory(prefix='rawlab-family-') as work:
        native = Path(work) / 'native'
        result, before, executable, ignored = run_decoder(decoder, raw, native, pipeline)
        protocol = json.loads((native / 'protocol.json').read_text())
        validate_protocol(protocol, raw, pipeline)
        evidence = {
            'role': 'native-family-diagnostic-not-SPP-equivalence',
            'source_path': str(raw), 'source_sha256': before,
            'decoder_path': str(decoder), 'decoder_sha256': executable,
            'build_contract': contract, 'ignored_environment_keys': ignored,
            'protocol': protocol, 'native_metadata': (native / 'metadata.txt').read_text(),
            'native_stdout': result.stdout, 'native_stderr': result.stderr,
            'source_sha256_by_file': {name: digest(Path(__file__).with_name(name)) for name in
                                     ('decode_family.rs', 'render_family.py', 'family_contract.py', 'scene_cache.py')},
            'limitations': ['Uses fixed native settings, not all saved user adjustments',
                            'AsShot follows the decoder camera-mode resolver; inspect its warnings',
                            'No per-camera SPP equivalence is implied by successful decoding'],
        }
        return publish_output(native / 'render.tif', output, evidence)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--decoder', required=True, type=Path)
    parser.add_argument('--contract', required=True, type=Path)
    parser.add_argument('--pipeline', choices=PIPELINES, required=True)
    parser.add_argument('raw', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    report = render(args.decoder, args.raw, args.output, args.pipeline,
                    json.loads(args.contract.read_text()))
    print(json.dumps({'output': str(args.output), 'shape': report['shape'],
                      'pipeline': args.pipeline, 'settings_policy': SETTINGS_POLICY}))


if __name__ == '__main__':
    main()
