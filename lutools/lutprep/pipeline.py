from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio

from .color import ColorSpaces, apply_processor, neutral_linear, srgb_encode


def file_processor(source, interpolation="linear"):
    # OCIO caches file contents by path; preparation must see a replaced source.
    ocio.ClearAllCaches()
    mode = ocio.INTERP_LINEAR if interpolation == "linear" else ocio.INTERP_TETRAHEDRAL
    transform = ocio.FileTransform(src=str(Path(source).resolve()), interpolation=mode)
    try:
        return ocio.Config.CreateRaw().getProcessor(transform).getDefaultCPUProcessor()
    except ocio.Exception as error:
        raise ValueError(f"Cannot read source LUT: {error}") from error


class LUTPipeline:
    def __init__(self, source, contract):
        self.contract = contract
        config = contract.ocio or {}
        self.spaces = ColorSpaces(config.get("config"), config.get("reference_space"))
        self.spaces.validate(contract.input.space)
        self.spaces.validate(contract.output.space)
        self.processor = file_processor(source, contract.interpolation)

    def evaluate(self, canonical_rgb):
        source, target = self.contract.input, self.contract.output
        linear = self.spaces.convert(canonical_rgb, "flog2-fgamut", "linear-srgb")
        if source.reference == "display":
            linear = neutral_linear(linear)
        encoded = self.spaces.convert(linear, "linear-srgb", source.space)
        if source.range == "legal10":
            encoded = (64 + 876 * encoded) / 1023
        result = apply_processor(self.processor, encoded)
        if target.range == "legal10":
            result = (1023 * result - 64) / 876
        linear = self.spaces.convert(result, target.space, "linear-srgb")
        if target.reference == "scene":
            linear = neutral_linear(linear)
        result = np.clip(srgb_encode(linear), 0, 1)
        if not np.all(np.isfinite(result)):
            raise ValueError("LUT composition produced nonfinite values")
        return result
