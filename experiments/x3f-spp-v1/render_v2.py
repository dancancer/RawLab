"""有界基础响应、保存色调曲线及空间 Fill Light 的离线组合原型。"""

import argparse
import json
from pathlib import Path
import tempfile
import numpy as np

from bounded_lut import compress_scene, interpolate
from calibration import rotate_saved
from saved_controls import apply_curve, apply_fill, apply_saturation
from saved_settings import read_saved_settings
from scene_cache import decode_fresh


def validate_settings(settings):
    if settings.white_balance == "Monochrome":
        raise ValueError("Saved Monochrome rendering is not implemented")
    if settings.unknown_adjustments:
        raise ValueError(f"Unknown nonzero saved adjustments: {settings.unknown_adjustments}")
    if settings.sharpness != 0:
        raise ValueError("Nonzero saved sharpness is not implemented")
    for name in ("contrast", "shadow", "highlight", "saturation"):
        if abs(getattr(settings, name)) > .500001:
            raise ValueError(f"Saved {name} is outside the calibrated range")
    if not -.500001 <= settings.fill_light <= .600001:
        raise ValueError("Saved Fill Light is outside the experimental range")


def render_scene(scene, settings, base, controls, fill, chunk_rows=128):
    validate_settings(settings)
    if scene.ndim != 3 or scene.shape[-1] != 3 or chunk_rows < 1 or not np.all(np.isfinite(scene)):
        raise ValueError("Invalid scene data")
    # 保存的颜色轮增益是颜色响应参数；不能直接当成最终 sRGB 的三个乘数。
    color_ev = np.asarray(controls["color_log_gain_matrix"]) @ np.log2(settings.color_adjustment)
    gain = 2 ** (color_ev + settings.exposure)
    axis, nodes = np.asarray(base["axis"]), np.asarray(base["nodes"])
    image = np.empty(scene.shape, dtype=np.float32)
    for y in range(0, scene.shape[0], chunk_rows):
        block = scene[y:y + chunk_rows]
        image[y:y + chunk_rows] = interpolate(compress_scene(block * gain), axis, nodes).reshape(block.shape)
    for name in controls["tone_order"]:
        amount = getattr(settings, name)
        if amount:
            image = apply_curve(image, amount, controls["tone_curves"][name])
    image = apply_saturation(image, settings.saturation)
    # Fill 模型在可显示颜色域上校准；局部均值在整图计算，分块只控制运算内存。
    return apply_fill(np.clip(image, 0, 1), settings.fill_light, fill, chunk_rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decoder", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output already exists")
    settings = read_saved_settings(args.raw)
    validate_settings(settings)
    model = json.loads(args.model.read_text())
    source = args.raw.resolve()
    with tempfile.TemporaryDirectory(prefix="rawlab-x3f-v2-") as work:
        scene, _ = decode_fresh(args.decoder, source, work, settings)
        scene = rotate_saved(scene, settings.rotation)
        output = render_scene(scene, settings, model["base"], model["controls"], model["fill"])
    from PIL import ImageCms
    import tifffile
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(args.output, np.rint(np.clip(output, 0, 1) * 65535).astype(np.uint16),
                     photometric="rgb", metadata=None, software="RawLab X3F offline experiment v2",
                     resolution=(180, 180), resolutionunit="INCH",
                     extratags=[(34675, "B", len(profile), profile, False)])
    print(json.dumps({"output": str(args.output), "shape": list(output.shape),
                      "out_of_range_fraction": float(np.mean((output < 0) | (output > 1))),
                      "saved_settings": settings.to_dict()}))


if __name__ == "__main__":
    main()
