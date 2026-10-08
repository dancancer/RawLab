from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio


# Keep these bridge matrices and curves aligned with color_converter.cpp.
SRGB_TO_XYZ = np.array([[.4124564, .3575761, .1804375],
                        [.2126729, .7151522, .0721750],
                        [.0193339, .1191920, .9503041]])
FGAMUT_TO_XYZ = np.array([[.6369580, .1446169, .1688810],
                         [.2627002, .6779981, .0593017],
                         [0., .0280727, 1.0609851]])
FGAMUT_TO_SRGB = np.linalg.solve(SRGB_TO_XYZ, FGAMUT_TO_XYZ)


def srgb_encode(value):
    x = np.asarray(value, dtype=np.float64)
    return np.where(x <= .0031308, 12.92 * x, 1.055 * np.maximum(x, 0) ** (1 / 2.4) - .055)


def srgb_decode(value):
    x = np.asarray(value, dtype=np.float64)
    return np.where(x <= .04045, x / 12.92, np.maximum((x + .055) / 1.055, 0) ** 2.4)


def flog2_encode(value):
    x = np.asarray(value, dtype=np.float64)
    encoded = np.where(x < .00088899597, 8.799461 * x + .092864,
                       .245281 * np.log10(np.maximum(5.555556 * x + .064829, 1e-30)) + .384316)
    return np.clip(encoded, 0, 1)


def flog2_decode(value):
    x = np.asarray(value, dtype=np.float64)
    return np.where(x < 8.799461 * .00088899597 + .092864,
                    (x - .092864) / 8.799461,
                    (10 ** ((x - .384316) / .245281) - .064829) / 5.555556)


def neutral_linear(value):
    x = np.asarray(value, dtype=np.float64)
    gray = .1845
    result = 1 / (1 + (1 - gray) / gray * (gray / np.maximum(x, 1e-20)) ** 1.5)
    return np.where(x > 0, result, 0)


def matrix_transform(matrix):
    full = np.eye(4)
    full[:3, :3] = matrix
    return ocio.MatrixTransform(matrix=full.ravel().tolist())


def apply_processor(processor, rgb):
    result = np.array(rgb, dtype=np.float32, order="C", copy=True)
    if result.ndim < 1 or result.shape[-1] != 3 or not np.all(np.isfinite(result)):
        raise ValueError("Expected finite RGB triples")
    processor.applyRGB(result)
    if not np.all(np.isfinite(result)):
        raise ValueError("Color transform produced nonfinite values")
    return result.astype(np.float64)


SCENE_BUILTINS = {
    "aces2065-1": "IDENTITY",
    "acescg": "ACEScg_to_ACES2065-1",
    "acescc": "ACEScc_to_ACES2065-1",
    "acescct": "ACEScct_to_ACES2065-1",
    "slog3-sgamut3": "SONY_SLOG3-SGAMUT3_to_ACES2065-1",
    "slog3-sgamut3-cine": "SONY_SLOG3-SGAMUT3.CINE_to_ACES2065-1",
    "logc3-awg": "ARRI_ALEXA-LOGC-EI800-AWG_to_ACES2065-1",
    "logc4-awg4": "ARRI_LOGC4_to_ACES2065-1",
    "clog2-cgamut": "CANON_CLOG2-CGAMUT_to_ACES2065-1",
    "clog3-cgamut": "CANON_CLOG3-CGAMUT_to_ACES2065-1",
    "vlog-vgamut": "PANASONIC_VLOG-VGAMUT_to_ACES2065-1",
    "log3g10-redwidegamut": "RED_LOG3G10-RWG_to_ACES2065-1",
}
DISPLAY_BUILTINS = {
    "rec709-gamma24": "DISPLAY - CIE-XYZ-D65_to_REC.1886-REC.709 - MIRROR NEGS",
    "display-p3": "DISPLAY - CIE-XYZ-D65_to_DisplayP3",
}


class ColorSpaces:
    def __init__(self, config=None, reference_space=None):
        self.config = ocio.Config.CreateRaw()
        self.custom = None
        self.reference_space = reference_space
        if config is not None:
            self.custom = ocio.Config.CreateFromFile(str(Path(config).resolve()))
            reference = self.custom.getColorSpace(reference_space or "")
            if (reference is None or reference.isData()
                    or reference.getReferenceSpaceType() != ocio.REFERENCE_SPACE_SCENE):
                raise ValueError("OCIO reference_space must name the config's scene-linear sRGB space")
        self._processors = {}
        self.names = ["linear-srgb", "linear-rec2020", "flog2-fgamut", "srgb",
                      *SCENE_BUILTINS, *DISPLAY_BUILTINS]
        if self.custom:
            self.names.extend("ocio:" + name for name in self.custom.getColorSpaceNames())

    def validate(self, name):
        if name not in self.names:
            raise ValueError(f"Unknown color space: {name}; run 'spaces' or declare a custom OCIO config")
        if name.startswith("ocio:") and self.custom.getColorSpace(name[5:]).isData():
            raise ValueError(f"OCIO data space cannot describe LUT colors: {name}")

    def _processor(self, name, inverse):
        key = (name, inverse)
        if key not in self._processors:
            if name.startswith("ocio:"):
                src, dst = name[5:], self.reference_space
                if inverse:
                    src, dst = dst, src
                processor = self.custom.getProcessor(src, dst)
            else:
                group = ocio.GroupTransform()
                if name in SCENE_BUILTINS:
                    group.appendTransform(ocio.BuiltinTransform(style=SCENE_BUILTINS[name]))
                    group.appendTransform(ocio.BuiltinTransform(style="UTILITY - ACES-AP0_to_CIE-XYZ-D65_BFD"))
                else:
                    group.appendTransform(ocio.BuiltinTransform(style=DISPLAY_BUILTINS[name],
                                                               direction=ocio.TRANSFORM_DIR_INVERSE))
                group.appendTransform(matrix_transform(np.linalg.inv(SRGB_TO_XYZ)))
                direction = ocio.TRANSFORM_DIR_INVERSE if inverse else ocio.TRANSFORM_DIR_FORWARD
                processor = self.config.getProcessor(group, direction)
            self._processors[key] = processor.getDefaultCPUProcessor()
        return self._processors[key]

    def convert(self, rgb, source, target):
        self.validate(source)
        self.validate(target)
        x = np.asarray(rgb, dtype=np.float64)
        if x.ndim < 1 or x.shape[-1] != 3 or not np.all(np.isfinite(x)):
            raise ValueError("Expected finite RGB triples")
        if source == target:
            return x.copy()
        if source == "srgb":
            linear = srgb_decode(x)
        elif source == "flog2-fgamut":
            linear = flog2_decode(x) @ FGAMUT_TO_SRGB.T
        elif source == "linear-rec2020":
            linear = x @ FGAMUT_TO_SRGB.T
        elif source == "linear-srgb":
            linear = x
        else:
            linear = apply_processor(self._processor(source, False), x)
        if target == "srgb":
            return srgb_encode(linear)
        if target == "flog2-fgamut":
            return flog2_encode(linear @ np.linalg.inv(FGAMUT_TO_SRGB).T)
        if target == "linear-rec2020":
            return linear @ np.linalg.inv(FGAMUT_TO_SRGB).T
        if target == "linear-srgb":
            return linear
        return apply_processor(self._processor(target, True), linear)
