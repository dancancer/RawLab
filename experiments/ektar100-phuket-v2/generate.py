"""A stronger default EKTAR-inspired look, retaining the v1 working-space contract."""

import argparse
import importlib.util
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('ektar_v1', HERE.parent / 'ektar100-phuket-v1/color_lut.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

FILENAME = 'EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65.cube'
PARAMETERS = {
    **base.PARAMETERS,
    'tone_contrast': 1.82,
    'overall_chroma': 1.105,
    'green_chroma_extra': .105,
    'blue_chroma_extra': .120,
    'skin_chroma_reduction': .125,
    'green_hue_degrees': -4.0,
    'blue_hue_degrees': -5.0,
    'green_lightness': -.014,
    'blue_lightness': -.013,
}


def render(encoded):
    return base.ektar(encoded, PARAMETERS)


def make_table():
    values = np.linspace(0, 1, 65)
    b, g, r = np.meshgrid(values, values, values, indexing='ij')
    return render(np.stack([r, g, b], axis=-1))


def write(path, table):
    path.parent.mkdir(parents=True, exist_ok=True)
    base.write_cube(path, table, 'EKTAR 100 Phuket v2 Strong - FLog2 FGamut to sRGB')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'output/ektar100-phuket-v2' / FILENAME)
    args = parser.parse_args()
    write(args.output, make_table())
    print(args.output)
