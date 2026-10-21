"""Regenerate the synthetic Bayer fixture; requires numpy and tifffile.

This generated image has no photographic source or camera-calibration meaning.
"""
import sys
from pathlib import Path

import numpy as np
import tifffile


def main():
    width, height = 128, 96
    y, x = np.mgrid[:height, :width]
    rng = np.random.default_rng(50918)
    rgb = np.stack((.08 + .25*x/width, .12 + .18*y/height,
                    .10 + .12*(x+y)/(width+height)), axis=-1)
    edge = x > y + 24
    rgb[edge] += (.11, .03, .08)
    texture = (x > 32) & (x < 96) & (y > 24) & (y < 72)
    rgb[texture] += (.035*np.sin(x*.8)*np.cos(y*.6))[texture, None]
    rgb += rng.normal(0, .012, rgb.shape)
    cfa = np.array([[0, 1], [1, 2]])[y % 2, x % 2]
    signal = np.take_along_axis(rgb, cfa[..., None], axis=-1)[..., 0]
    pixels = np.clip(64 + 4031*signal, 64, 4095).astype(np.uint16)
    matrix = [3.2406, -1.5372, -.4986, -.9689, 1.8758, .0415, .0557, -.2040, 1.0570]
    rationals = tuple(value for entry in matrix for value in (round(entry*10000), 10000))
    tags = [
        (271, "s", 0, "RawLab", False), (272, "s", 0, "Demosaic fixture", False),
        (274, "H", 1, 1, False),
        (33421, "H", 2, (2, 2), False), (33422, "B", 4, (0, 1, 1, 2), False),
        (50706, "B", 4, (1, 4, 0, 0), False), (50707, "B", 4, (1, 3, 0, 0), False),
        (50708, "s", 0, "RawLab synthetic Bayer", False),
        (50710, "B", 3, (0, 1, 2), False), (50711, "H", 1, 1, False),
        (50713, "H", 2, (1, 1), False), (50714, "2I", 1, (64, 1), False),
        (50717, "I", 1, 4095, False), (50721, "2i", 9, rationals, False),
        (50728, "2I", 3, (1, 2, 1, 1, 2, 3), False), (50778, "H", 1, 21, False),
    ]
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(output, pixels, photometric=32803, metadata=None, extratags=tags)


if __name__ == "__main__":
    main()
