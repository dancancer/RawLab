"""按明确的数据划分评估冻结原型；默认只读开发图片，不重新拟合。"""

import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image

from calibration import measure, reduce_reference, rotate_saved
from compare_corpus import load_reference
from frozen_render import render as render_v1
from render_v2 import render_scene, validate_settings
from saved_settings import read_saved_settings
from scene_cache import load_scene
from evaluation_contract import paired_summary, source_hashes, validate_frozen, version_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("data", "model", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--scene", type=Path)
    parser.add_argument("--v1-model", type=Path)
    parser.add_argument("--split", choices=["development", "holdout"], default="development")
    parser.add_argument("--files", nargs="+", help="Optional explicit source filenames for a full-resolution subset")
    args = parser.parse_args()
    manifest = json.loads((args.data / "manifest.json").read_text())
    model = json.loads(args.model.read_text())
    if args.split == "holdout":
        validate_frozen(model, manifest, hashlib.sha256((args.data / "manifest.json").read_bytes()).hexdigest(), source_hashes())
    old_model = json.loads(args.v1_model.read_text()) if args.v1_model else None
    scene_directory = args.scene or args.data / "scene-linear"
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in manifest["samples"]:
        if args.files and row["file"] not in args.files:
            continue
        is_holdout = row["split"] == "holdout"
        if is_holdout != (args.split == "holdout"):
            continue
        stem = Path(row["file"]).stem
        source = args.data / "inputs" / row["file"]
        settings = read_saved_settings(source)
        if hashlib.sha256(source.read_bytes()).hexdigest() != row["sha256"]:
            raise ValueError(f"{stem}: source hash differs")
        reference_path = Path(row["reference"]["path"])
        if hashlib.sha256(reference_path.read_bytes()).hexdigest() != row["reference"]["sha256"]:
            raise ValueError(f"{stem}: reference hash differs")
        try:
            validate_settings(settings)
        except ValueError as error:
            results.append({"file": stem, "group": row["scene_group"], "status": "unsupported", "reason": str(error)})
            print(json.dumps(results[-1]), flush=True)
            continue
        scene, meta = load_scene(source, scene_directory / stem, settings)
        scene = rotate_saved(scene, settings.rotation)
        reference = reduce_reference(load_reference(reference_path), meta["block"])
        actual = render_scene(scene, settings, model["base"], model["controls"], model["fill"])
        metrics = measure(actual, reference)
        bounded = np.clip(actual, 0, 1)
        metrics["false_white_fraction"] = float(np.mean(np.all(bounded > .995, axis=-1) & np.any(reference < .97, axis=-1)))
        result = {"file": stem, "group": row["scene_group"], "status": "measured", "block": meta["block"], "v2": metrics}
        if old_model:
            try:
                baseline = render_v1(scene, settings, np.array(meta["camera_to_rgb"]).reshape(3, 3), old_model)
                result["v1"] = measure(baseline, reference)
                result["v1"]["false_white_fraction"] = float(np.mean(np.all(np.clip(baseline, 0, 1) > .995, axis=-1)
                                                                   & np.any(reference < .97, axis=-1)))
            except ValueError as error:
                result["v1_unsupported"] = str(error)
        results.append(result)
        for suffix, pixels in [("candidate", bounded), ("reference", reference)]:
            preview = Image.fromarray(np.rint(pixels * 255).astype(np.uint8))
            preview.thumbnail((1000, 1000))
            preview.save(args.output / f"{stem}-{suffix}.jpg", quality=95)
        print(json.dumps(result), flush=True)
    if not results:
        raise ValueError("No source files matched the requested evaluation")
    summary = {kind: version_summary(results, kind) for kind in ("v1", "v2")}
    blocks = sorted({row["block"] for row in results if row["status"] == "measured"})
    if len(blocks) > 1:
        raise ValueError("Do not mix reduced and full-resolution measurements in one report")
    report = {"split": args.split, "model_sha256": hashlib.sha256(args.model.read_bytes()).hexdigest(),
              "summary": summary, "paired": paired_summary(results), "images": results,
              "scene_blocks": blocks, "decoder_revision": "00f9ef206a2d629bca35ceead4b3951833b85d3d",
              "source_sha256": source_hashes(), "unsupported_count": sum(r["status"] == "unsupported" for r in results)}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
