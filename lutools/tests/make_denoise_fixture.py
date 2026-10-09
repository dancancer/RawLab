"""Create a small, deterministic Bayer DNG for native-client denoise tests.

Requires numpy and tifffile. The generated file is a test artifact, not a photo.
"""
import sys
from pathlib import Path

import numpy as np
import tifffile

size = 512
rng = np.random.default_rng(50917)
y, x = np.mgrid[:size, :size]
signal = np.full((size, size), 0.18)
texture = (x > 160) & (x < 352) & (y > 160) & (y < 352)
signal[texture] += (0.025 * np.sin(x * 0.3) * np.cos(y * 0.2))[texture]
raw = np.clip(64 + 4031 * (signal + rng.normal(0, 0.014, signal.shape)), 0, 4095).astype(np.uint16)
matrix = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
rationals = tuple(value for entry in matrix for value in (round(entry * 10000), 10000))
tags = [
    (271, "s", 0, "RawLab", False), (272, "s", 0, "Denoise test fixture", False),
    (33421, "H", 2, (2, 2), False), (33422, "B", 4, (0, 1, 1, 2), False),
    (50706, "B", 4, (1, 4, 0, 0), False), (50707, "B", 4, (1, 3, 0, 0), False),
    (50708, "s", 0, "RawLab synthetic Bayer", False),
    (50710, "B", 3, (0, 1, 2), False), (50711, "H", 1, 1, False),
    (50713, "H", 2, (1, 1), False), (50714, "2I", 1, (64, 1), False),
    (50717, "I", 1, 4095, False), (50721, "2i", 9, rationals, False),
    (50728, "2I", 3, (1, 1, 1, 1, 1, 1), False), (50778, "H", 1, 21, False),
]
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
tifffile.imwrite(output, raw, photometric=32803, metadata=None, extratags=tags)
print(f"Created synthetic {size}x{size} Bayer DNG: {output}")
