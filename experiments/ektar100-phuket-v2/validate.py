"""Compare both LUTs on identical frozen RAW decodes, not on already graded JPEGs."""

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

import generate as look

V1 = look.HERE.parent / 'ektar100-phuket-v1'
sys.path.insert(0, str(V1))
from render_comparisons import ICC, make_row, read_pfm, save_rgb


def validate(output):
    output.mkdir(parents=True, exist_ok=True)
    before = look.base.read_cube(V1 / '.cache/ektar-smoke.cube')
    after = look.base.read_cube(output / look.FILENAME)
    if after.shape != (65, 65, 65, 3) or not np.isfinite(after).all():
        raise ValueError('Expected finite 65-grid LUT')
    rows, records = [], []
    for source in sorted((V1 / '.cache').glob('*.log.pfm')):
        name = source.name.removesuffix('.log.pfm')
        encoded = read_pfm(source)
        old = look.base.apply_cube(before, encoded)
        new = look.base.apply_cube(after, encoded)
        if not np.isfinite(new).all() or new.min() < 0 or new.max() > 1:
            raise ValueError(f'Invalid output: {name}')
        old_path, new_path = output / f'{name}-v1.jpg', output / f'{name}-v2.jpg'
        save_rgb(old, old_path)
        save_rgb(new, new_path)
        row = output / f'{name}-comparison.jpg'
        make_row([('v1 | 100%', old_path), ('v2 Strong | 100%', new_path)],
                 f'{name} | Same RAW decode, camera WB and exposure', row)
        rows.append(row)
        records.append({
            'sample': name,
            'development': source.with_name(f'{name}.txt').read_text().strip(),
            'mean_absolute_rgb_change': float(np.abs(new - old).mean()),
            'pixels_with_channel_at_zero': float(np.any(new <= 0, axis=-1).mean()),
            'pixels_with_channel_at_one': float(np.any(new >= 1, axis=-1).mean()),
            'range': [float(new.min()), float(new.max())],
        })
        print(f'Checked {name}', flush=True)
    if not records:
        raise ValueError('No frozen RAW decodes; generate v1 reference cache first')
    for start in range(0, len(rows), 3):
        selected = [Image.open(path) for path in rows[start:start + 3]]
        sheet = Image.new('RGB', (selected[0].width, sum(im.height for im in selected)))
        y = 0
        for image in selected:
            sheet.paste(image, (0, y))
            y += image.height
            image.close()
        sheet.save(output / f'comparison-sheet-{start // 3 + 1}.jpg', quality=95, icc_profile=ICC)
    report = {
        'parameters_v1': look.base.PARAMETERS,
        'parameters_v2': look.PARAMETERS,
        'lut_size': 65,
        'strength': 'Both compared at 100%; no app default changed.',
        'method': 'Frozen v1 linear RAW processing, F-Log2/F-Gamut cache, trilinear LUT sampling.',
        'samples': records,
        'claim': 'Stronger artistic interpretation, not measured film reproduction or a new RAW decoder test.',
    }
    (output / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    validate(look.ROOT / 'output/ektar100-phuket-v2')
