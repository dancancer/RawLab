"""从 X3F 输出实验性 sRGB16 TIFF；仅使用解码器、保存设置及冻结模型。"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import numpy as np
from PIL import ImageCms
import tifffile

from calibration import rotate_saved
from frozen_render import render
from saved_settings import read_saved_settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decoder", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--denoise", type=int, choices=range(11), default=0)
    parser.add_argument("--highlight-recovery", action="store_true")
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output already exists")
    settings = read_saved_settings(args.raw)
    model = json.loads(args.model.read_text())
    source = args.raw.resolve()
    with tempfile.TemporaryDirectory(prefix="rawlab-x3f-render-") as work:
        subprocess.run([str(args.decoder.resolve()), "1", str(args.denoise),
                        str(int(args.highlight_recovery)), work, str(source)], check=True)
        meta = json.loads((Path(work) / f"{source.stem}.json").read_text())
        scene = np.fromfile(Path(work) / f"{source.stem}.f32", dtype="<f4")
        scene = scene.reshape(meta["height"], meta["width"], 3)
        if meta["block"] != 1 or not np.all(np.isfinite(scene)):
            raise ValueError("Expected full-resolution finite scene data")
        scene = rotate_saved(scene, settings.rotation)
        output = render(scene, settings, np.array(meta["camera_to_rgb"]).reshape(3, 3), model)
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(args.output, np.rint(np.clip(output, 0, 1) * 65535).astype(np.uint16),
                     photometric="rgb", metadata=None, software="RawLab X3F offline experiment v1",
                     resolution=(180, 180), resolutionunit="INCH",
                     extratags=[(34675, "B", len(icc), icc, False)])
    print(json.dumps({"output": str(args.output), "shape": list(output.shape),
                      "model_channel_out_of_range_fraction": float(np.mean((output < 0) | (output > 1))),
                      "saved_settings": settings.to_dict()}))


if __name__ == "__main__":
    main()
