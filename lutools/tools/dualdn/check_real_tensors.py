#!/usr/bin/env python3
"""Compare pinned PyTorch and native ONNX graphs on external real RAW crops.

Cases contain path, id and noise_new: {k, b}. These are numerical test inputs;
cross-camera or extrapolated cases do not extend the product calibration domain.
"""
import argparse
import json
import shutil
from pathlib import Path
import subprocess
import tempfile

import numpy as np
import rawpy
import torch
import export as dualdn


def camera_matrix(raw):
    xyz_rgb = np.array([[3.2404542, -1.5371385, -.4985314],
                        [-.969266, 1.8760108, .041556], [.0556434, -.2040259, 1.0572252]], np.float32)
    xyz_rgb /= xyz_rgb.sum(1, keepdims=True)
    matrix = np.array(raw.rgb_xyz_matrix[:3, :3], np.float32)
    if np.all(matrix != 0):
        return np.linalg.inv(matrix / matrix.sum(1, keepdims=True)).astype(np.float32)
    matrix = np.linalg.inv(xyz_rgb) @ np.array(raw.color_matrix[:3, :3], np.float32)
    return (matrix / matrix.sum(1, keepdims=True)).astype(np.float32)


def inputs(case):
    with rawpy.imread(case['path']) as raw:
        mosaic = np.asarray(raw.raw_image_visible)
        pattern = raw.raw_pattern
        red_y, red_x = np.argwhere(pattern == 0)[0]
        # 偶数起点加相位偏移，取同一个 RGGB 上下文给两个后端。
        top = max(0, (mosaic.shape[0] // 2 - 640) // 2 * 2) + int(red_y)
        left = max(0, (mosaic.shape[1] // 2 - 640) // 2 * 2) + int(red_x)
        crop = mosaic[top:top+1280, left:left+1280].astype(np.float32)
        if crop.shape != (1280, 1280):
            raise ValueError('Real RAW parity needs at least 1282 x 1282 pixels')
        ids = [int(pattern[(red_y+y) % 2, (red_x+x) % 2]) for y, x in [(0,0),(0,1),(1,0),(1,1)]]
        for phase, identity in enumerate(ids):
            black = raw.black_level_per_channel[identity]
            crop[phase//2::2, phase%2::2] = np.maximum((crop[phase//2::2, phase%2::2]-black)/(raw.white_level-black), 1e-8)
        packed = np.stack([crop[y::2,x::2] for y,x in [(0,0),(0,1),(1,0),(1,1)]])[None]
        camera_wb = raw.camera_whitebalance
        if camera_wb[0] == 0:
            camera_wb = raw.daylight_whitebalance
        wb = np.array([camera_wb[0], camera_wb[ids[1]], camera_wb[2], camera_wb[ids[2]]], np.float32)
        if wb[3] == 0:
            wb[3] = wb[1]
        return torch.from_numpy(packed), torch.from_numpy(crop[320:960,320:960][None,None]), torch.from_numpy(wb[None,None,None]), torch.from_numpy(camera_matrix(raw)[None,None])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'weights', 'model-package', 'cases', 'native-runner', 'output']:
        parser.add_argument('--'+name, required=True, type=Path)
    parser.add_argument('--threads', type=int, default=6)
    parser.add_argument('--diagnostic', action='store_true', help='Collect errors without claiming numerical acceptance')
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    manifest = json.loads((args.model_package/'manifest.json').read_text())
    if manifest['tile_size'] != 640:
        raise ValueError('Production 640-pixel package required')
    model, pipeline = dualdn.load_model(args.source, args.weights)
    raw_head, rgb_head, isp = dualdn.RawHead(model).eval(), dualdn.RgbHead(model).eval(), dualdn.OfficialISP(pipeline,640).eval()
    args.output.mkdir(parents=True, exist_ok=False)
    reports = {}
    for case in json.loads(args.cases.read_text()):
        with torch.inference_mode():
            packed, noisy, wb, matrix = inputs(case)
            k = torch.tensor([[[[case['noise_new']['k']]]]], dtype=torch.float32)
            b = torch.tensor([[[[case['noise_new']['b']]]]], dtype=torch.float32)
            raw_result = raw_head(packed, k, b)
            clean = torch.nn.functional.pixel_shuffle(raw_result, 2)[:,:,320:960,320:960].contiguous()
            skip = isp(clean, wb, matrix)
            noise_rgb = isp((noisy*k+b).clamp(min=1e-7).sqrt(), wb, matrix)
            rgb_result = rgb_head(skip, noise_rgb)
        with tempfile.TemporaryDirectory(prefix='replay-', dir=args.output) as directory:
            root = Path(directory)
            (root/'manifest.json').write_text(json.dumps(manifest))
            for name in ['raw','isp','rgb']:
                (root/(name+'.onnx')).symlink_to((args.model_package/(name+'.onnx')).resolve())
            values = {'raw-packed_raw':packed, 'raw-k':k, 'raw-b':b, 'raw-expected':raw_result,
                'isp-mosaic':clean, 'isp-wb':wb, 'isp-camera_to_xyz':matrix, 'isp-expected':skip,
                'rgb-skip_rgb':skip, 'rgb-noise_rgb':noise_rgb, 'rgb-expected':rgb_result,
                'pipeline-noisy_mosaic':noisy}
            for name, value in values.items():
                value.numpy().astype('<f4').tofile(root/(name+'.f32'))
            command = [str(args.native_runner), str(root), 'cpu']
            if args.diagnostic:
                command.append('--diagnostic')
            result = subprocess.run(command, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(case['id'] + '\n' + result.stdout + '\n' + result.stderr)
            report = json.loads(result.stdout[result.stdout.rfind('\n{\n')+1:])
            if args.diagnostic:
                shutil.copytree(root, args.output/case['id'], symlinks=True)
        reports[case['id']] = {'graphs':report, 'camera':case['model'], 'iso':case['iso'],
                               'parameter_origin':case['parameter_origin'], 'cross_body':case['cross_body']}
        (args.output/'summary.json').write_text(json.dumps(reports, indent=2)+'\n')
        print(case['id'], json.dumps(report), flush=True)
    print('DIAGNOSTIC' if args.diagnostic else 'PASS', len(reports), 'real RAW tensor cases', flush=True)


if __name__ == '__main__':
    main()
