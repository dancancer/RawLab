"""Independent scan-inspired look. No Fujifilm table values are baked into it."""

from pathlib import Path

import numpy as np


# Match the existing RawLab working-space matrices, not F-Gamut C.
SRGB_TO_XYZ = np.array([[.4124564, .3575761, .1804375],
                        [.2126729, .7151522, .0721750],
                        [.0193339, .1191920, .9503041]])
FGAMUT_TO_XYZ = np.array([[.6369580, .1446169, .1688810],
                          [.2627002, .6779981, .0593017],
                          [0, .0280727, 1.0609851]])
FGAMUT_TO_SRGB = np.linalg.solve(SRGB_TO_XYZ, FGAMUT_TO_XYZ)
SRGB_TO_FGAMUT = np.linalg.inv(FGAMUT_TO_SRGB)

# Bjorn Ottosson's public-domain Oklab reference, updated 2021-01-25.
# https://bottosson.github.io/posts/oklab/
RGB_TO_LMS = np.array([[.4122214708, .5363325363, .0514459929],
                       [.2119034982, .6806995451, .1073969566],
                       [.0883024619, .2817188376, .6299787005]])
LMS_TO_LAB = np.array([[.2104542553, .7936177850, -.0040720468],
                       [1.9779984951, -2.4285922050, .4505937099],
                       [.0259040371, .7827717662, -.8086757660]])
LAB_TO_LMS = np.linalg.inv(LMS_TO_LAB)
LMS_TO_RGB = np.linalg.inv(RGB_TO_LMS)

PARAMETERS = {
    "scene_gamut_softness": .12,
    "tone_contrast": 1.62,
    "middle_gray": .1845,
    "overall_chroma": 1.055,
    "green_chroma_extra": .065,
    "blue_chroma_extra": .075,
    "skin_chroma_reduction": .075,
    "green_hue_degrees": -3.0,
    "blue_hue_degrees": -5.0,
    "skin_hue_degrees": 1.5,
    "green_lightness": -.009,
    "blue_lightness": -.008,
}


def flog2_decode(encoded):
    encoded = np.asarray(encoded, dtype=np.float64)
    cut = 8.799461 * .00088899597 + .092864
    return np.where(encoded < cut, (encoded - .092864) / 8.799461,
                    (10 ** ((encoded - .384316) / .245281) - .064829) / 5.555556)


def scene_to_log(rgb):
    linear = np.asarray(rgb) @ SRGB_TO_FGAMUT.T
    value = np.where(linear < .00088899597, 8.799461 * linear + .092864,
                     .245281 * np.log10(np.maximum(5.555556 * linear + .064829, 1e-30)) + .384316)
    return np.clip(value, 0, 1)


def srgb_encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear,
                    1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def tone_curve(linear, contrast=1.5):
    gray = PARAMETERS["middle_gray"]
    positive = np.maximum(linear, 0)
    power = positive ** contrast
    return power / (power + (1 - gray) / gray * gray ** contrast)


def linear_to_oklab(rgb):
    return np.cbrt(rgb @ RGB_TO_LMS.T) @ LMS_TO_LAB.T


def oklab_to_linear(lab):
    return ((lab @ LAB_TO_LMS.T) ** 3) @ LMS_TO_RGB.T


def hue_weight(hue, center, width):
    # Periodic, smooth weighting avoids discontinuities at the hue wrap.
    return np.exp((np.cos(hue - np.deg2rad(center)) - 1) / np.deg2rad(width) ** 2)


def compress_gamut(lab):
    colors = lab.reshape(-1, 3).copy()
    chroma = np.linalg.norm(colors[:, 1:], axis=-1)
    direction = colors[:, 1:] / np.maximum(chroma[:, None], 1e-15)
    low, high = np.zeros(len(colors)), np.full(len(colors), .5)
    for _ in range(18):
        amount = (low + high) * .5
        probe = colors.copy()
        probe[:, 1:] = direction * amount[:, None]
        candidate = oklab_to_linear(probe)
        fits = np.all((candidate >= 0) & (candidate <= 1), axis=-1)
        low = np.where(fits, amount, low)
        high = np.where(fits, high, amount)
    # Roll chroma off before the boundary; a hard boundary creates visible LUT interpolation errors.
    ratio = chroma / np.maximum(low, 1e-15)
    compressed = np.where(ratio <= .75, ratio,
                          .75 + .25 * (1 - np.exp(-np.maximum(ratio - .75, 0) / .25)))
    colors[:, 1:] = direction * (low * compressed)[:, None]
    return np.clip(oklab_to_linear(colors).reshape(lab.shape), 0, 1)


def neutral(log_rgb):
    scene = flog2_decode(log_rgb) @ FGAMUT_TO_SRGB.T
    return srgb_encode(tone_curve(scene))


def ektar(log_rgb):
    scene = flog2_decode(log_rgb) @ FGAMUT_TO_SRGB.T
    # Smooth negative-channel handling in wide-gamut colors, with gray kept invariant.
    radius = PARAMETERS["scene_gamut_softness"]
    luma = np.maximum(scene @ np.array([.2126, .7152, .0722]), 0)[..., None]
    scene = (scene + np.sqrt(scene ** 2 + (radius * luma) ** 2)) / (1 + np.sqrt(1 + radius ** 2))
    display = tone_curve(scene, PARAMETERS["tone_contrast"])
    lab = linear_to_oklab(display)
    lightness, a, b = np.moveaxis(lab, -1, 0)
    chroma = np.hypot(a, b)
    hue = np.arctan2(b, a)
    green = hue_weight(hue, 142, 24)
    blue = hue_weight(hue, 245, 32)
    skin = hue_weight(hue, 55, 25)
    colored = chroma ** 2 / (chroma ** 2 + .035 ** 2)
    midtones = np.sin(np.pi * np.clip(lightness, 0, 1)) ** 2
    saturation = (PARAMETERS["overall_chroma"] + PARAMETERS["green_chroma_extra"] * green
                  + PARAMETERS["blue_chroma_extra"] * blue
                  - PARAMETERS["skin_chroma_reduction"] * skin)
    chroma *= 1 + (saturation - 1) * midtones
    shift = (PARAMETERS["green_hue_degrees"] * green + PARAMETERS["blue_hue_degrees"] * blue
             + PARAMETERS["skin_hue_degrees"] * skin)
    hue += np.deg2rad(shift) * colored * midtones
    lightness = lightness + (PARAMETERS["green_lightness"] * green
                             + PARAMETERS["blue_lightness"] * blue) * colored * midtones
    graded = np.stack([lightness, chroma * np.cos(hue), chroma * np.sin(hue)], axis=-1)
    return srgb_encode(compress_gamut(graded))


def write_cube(path, table, title):
    n = table.shape[0]
    if table.shape != (n, n, n, 3) or not np.isfinite(table).all():
        raise ValueError("Expected a finite cubic RGB table")
    header = (f'TITLE "{title}"\n'
              '# Independent scan-inspired experimental look; not measured film calibration.\n'
              '#Gamma:F-Log2 to EKTAR 100 Phuket\n'
              '#Gamut:F-Gamut to ITU-R BT.709\n'
              '#OutputTransfer:sRGB\n'
              '# Input: full-range F-Log2, original F-Gamut, D65. Not F-Gamut C.\n'
              '# Does not include exposure baseline or white balance.\n'
              f'LUT_3D_SIZE {n}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
    with Path(path).open("w") as file:
        file.write(header)
        np.savetxt(file, table.reshape(-1, 3), fmt="%.9f")


def read_cube(path):
    size, data = None, []
    for line in Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if parts[0] == "LUT_3D_SIZE":
            size = int(parts[1])
        elif parts[0] == "DOMAIN_MIN":
            if [float(v) for v in parts[1:]] != [0, 0, 0]:
                raise ValueError("This experiment supports only unit-domain LUTs")
        elif parts[0] == "DOMAIN_MAX":
            if [float(v) for v in parts[1:]] != [1, 1, 1]:
                raise ValueError("This experiment supports only unit-domain LUTs")
        elif parts[0] != "TITLE":
            data.append([float(v) for v in parts])
    array = np.array(data, dtype=np.float64)
    if size is None or size < 2 or array.shape != (size ** 3, 3) or not np.isfinite(array).all():
        raise ValueError("Invalid or incomplete CUBE")
    return array.reshape(size, size, size, 3)


def apply_cube(table, rgb):
    size = table.shape[0]
    coord = np.clip(rgb, 0, 1) * (size - 1)
    base = np.minimum(np.floor(coord).astype(np.int32), size - 2)
    fraction = coord - base
    out = np.zeros_like(coord)
    for b in (0, 1):
        for g in (0, 1):
            for r in (0, 1):
                weight = np.prod(np.where(np.array([r, g, b]), fraction, 1 - fraction), axis=-1)
                out += table[base[..., 2] + b, base[..., 1] + g, base[..., 0] + r] * weight[..., None]
    return out


if __name__ == "__main__":
    values = np.linspace(0, 1, 65)
    b, g, r = np.meshgrid(values, values, values, indexing="ij")
    table = ektar(np.stack([r, g, b], axis=-1))
    path = Path(__file__).with_name("EKTAR_100_Phuket_v1_FLog2_FGamut_65.cube")
    write_cube(path, table, "EKTAR 100 Phuket v1 - FLog2 FGamut to sRGB")
    print(path)
