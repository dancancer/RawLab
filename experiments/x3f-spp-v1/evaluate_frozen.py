"""冻结模型的整图核验；先按原尺寸渲染，再测量或缩小，不重新拟合。"""

import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image

from calibration import measure, reduce_reference, rotate_saved
from compare_corpus import load_reference
from frozen_render import render
from saved_settings import read_saved_settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("data", "scene", "model", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--save-full", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((args.data / "manifest.json").read_text())
    model = json.loads(args.model.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in manifest["samples"]:
        stem = Path(row["file"]).stem
        metadata = args.scene / f"{stem}.json"
        if not metadata.exists():
            continue
        meta = json.loads(metadata.read_text())
        if meta["block"] != 1:
            raise ValueError("Full-resolution evaluation requires block size 1")
        settings = read_saved_settings(args.data / "inputs" / row["file"])
        scene = np.fromfile(args.scene / f"{stem}.f32", dtype="<f4")
        scene = rotate_saved(scene.reshape(meta["height"], meta["width"], 3), settings.rotation)
        actual = render(scene, settings, np.array(meta["camera_to_rgb"]).reshape(3, 3), model)
        reference = load_reference(row["reference"]["path"])
        metrics = measure(actual, reference)
        bounded = np.clip(actual, 0, 1)
        white = np.all(bounded > 0.995, axis=-1)
        metrics.update({
            "raw_min": float(actual.min()), "raw_max": float(actual.max()),
            "candidate_white_pixels": float(np.mean(white)),
            "reference_white_pixels": float(np.mean(np.all(reference > 0.995, axis=-1))),
            "false_white_pixels": float(np.mean(white & np.any(reference < 0.97, axis=-1))),
        })
        reduced_metrics = measure(reduce_reference(bounded, 8), reduce_reference(reference, 8))
        results.append({"file": stem, "split": row["split"], "denoise_intensity": meta["denoise_intensity"],
                        "full_resolution": metrics, "reduced_after_full_render": reduced_metrics})
        pixels = Image.fromarray(np.rint(bounded * 255).astype(np.uint8))
        if args.save_full:
            pixels.save(args.output / f"{stem}-full.png")
        pixels.thumbnail((1000, 1000))
        pixels.save(args.output / f"{stem}-preview.jpg", quality=95)
        print(json.dumps(results[-1]), flush=True)
    if not results:
        raise ValueError("No matching scene files to evaluate")
    report = {"model_sha256": hashlib.sha256(args.model.read_bytes()).hexdigest(), "images": results,
              "note": "Frozen model, no refit. Full resolution includes spatial/noise differences."
                      " Reusing these validation scenes for diagnosis does not create a new independent test set."}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
