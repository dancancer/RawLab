"""训练组内部选取响应模型，冻结后仅评估一次留出组。"""

import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image
import tifffile

from calibration import (fit_polynomial, measure, predict_polynomial,
                         reduce_reference, rotate_saved, srgb_decode, srgb_encode)
from saved_settings import read_saved_settings
from frozen_render import prepare_input


# 此轮 SPP 参考的实际 sRGB profile；已用 LittleCMS 的 17^3 色块确认到标准 sRGB 最大差 1/255。
SPP_SRGB_PROFILE_SHA256 = "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e"


def load_reference(path):
    with tifffile.TiffFile(path) as tiff:
        page = tiff.pages[0]
        reference = page.asarray()
        if reference.dtype.kind != "u" or reference.dtype.itemsize != 2 or 34675 not in page.tags:
            raise ValueError("Expected an ICC-tagged 16-bit SPP reference")
        if page.tags["Software"].value != "SIGMA Photo Pro 6.9.0":
            raise ValueError("Unexpected reference software")
        if hashlib.sha256(page.tags[34675].value).hexdigest() != SPP_SRGB_PROFILE_SHA256:
            raise ValueError("Unverified reference ICC profile; do not assume sRGB")
    return reference.astype(np.float64) / 65535


def load_samples(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    samples = []
    for row in manifest["samples"]:
        stem = Path(row["file"]).stem
        source = directory / "inputs" / row["file"]
        if hashlib.sha256(source.read_bytes()).hexdigest() != row["sha256"]:
            raise ValueError(f"{stem}: source hash differs from the frozen manifest")
        reference_path = Path(row["reference"]["path"])
        if hashlib.sha256(reference_path.read_bytes()).hexdigest() != row["reference"]["sha256"]:
            raise ValueError(f"{stem}: reference hash differs from the frozen manifest")
        settings = read_saved_settings(source)
        meta = json.loads((directory / "scene-linear" / f"{stem}.json").read_text())
        if meta["saved_header_white_balance"] != settings.white_balance or Path(meta["source_path"]) != source.resolve():
            raise ValueError(f"{stem}: scene metadata belongs to a different input or white balance")
        if meta["denoise_intensity"] != 0 or meta["highlight_recovery"]:
            raise ValueError("Model fitting protocol requires denoise=0 and recovery=false")
        scene = np.fromfile(directory / "scene-linear" / f"{stem}.f32", dtype="<f4")
        scene = scene.reshape(meta["height"], meta["width"], 3).astype(np.float64)
        scene = rotate_saved(scene, settings.rotation)
        reference = reduce_reference(load_reference(row["reference"]["path"]), meta["block"])
        if scene.shape != reference.shape:
            raise ValueError(f"{stem}: active crop/orientation differs")
        samples.append({"stem": stem, "group": row["scene_group"], "split": row["split"],
                        "settings": settings, "scene": scene, "reference": reference,
                        "matrix": np.array(meta["camera_to_rgb"]).reshape(3, 3),
                        "embedded": row["embedded"]})
    return samples


def fitting_input(sample, stage):
    return prepare_input(sample["scene"], sample["settings"], stage, sample["matrix"])


def fit(samples, stage, degree, use_context):
    xs, ys, cs = [], [], []
    for sample in samples:
        x, context = fitting_input(sample, stage)
        # 每张照片固定网格采样，避免某张高分辨率图支配拟合。
        xs.append(x[::9]); cs.append(context[::9])
        ys.append(sample["reference"].reshape(-1, 3)[::9])
    return fit_polynomial(np.concatenate(xs), np.concatenate(ys), degree,
                          np.concatenate(cs) if use_context else None)


def predict(sample, weights, stage, degree, use_context):
    x, context = fitting_input(sample, stage)
    return predict_polynomial(x, weights, degree, context if use_context else None).reshape(sample["scene"].shape)


def original_prototype(sample):
    preview = np.asarray(Image.open(sample["embedded"]).convert("RGB"), dtype=np.float64) / 255
    scene = sample["scene"]
    def median_luminance(image):
        rows = (2 * np.arange(128) + 1) * image.shape[0] // 256
        cols = (2 * np.arange(128) + 1) * image.shape[1] // 256
        return np.median(np.maximum(0, image[rows[:, None], cols[None, :]] @ [.2126, .7152, .0722]))
    gain = 2 ** np.clip(np.log2(median_luminance(srgb_decode(preview)) / max(1e-7, median_luminance(scene))), -8, 8)
    positive = np.maximum(scene * gain, 1e-15)
    display = 1 / (1 + (1 - .1845) / .1845 * (.1845 / positive) ** 1.5)
    return srgb_encode(np.where(scene > 0, display, 0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    samples = load_samples(args.data)
    train = [s for s in samples if s["split"] == "train"]
    groups = sorted({s["group"] for s in train})
    if set(groups) & {s["group"] for s in samples if s["split"] == "validation"}:
        raise ValueError("A scene group crosses the train/validation boundary")
    if not train or len(groups) < 2 or not any(s["split"] == "validation" for s in samples):
        raise ValueError("A frozen scene-group train/validation split is required")
    args.output.mkdir(parents=True, exist_ok=True)
    candidates = []
    for stage in ["none", "scene", "camera"]:
        for degree in [2, 3]:
            for use_context in [False, True]:
                scores = []
                for group in groups:
                    weights = fit([s for s in train if s["group"] != group], stage, degree, use_context)
                    held = [s for s in train if s["group"] == group]
                    scores.extend(measure(predict(s, weights, stage, degree, use_context), s["reference"])["delta_e76_mean"] for s in held)
                candidate = {"stage": stage, "degree": degree, "context": use_context,
                             "training_group_cv_delta_e76_mean": float(np.mean(scores))}
                candidates.append(candidate)
                print(json.dumps(candidate), flush=True)
    selected = min(candidates, key=lambda c: c["training_group_cv_delta_e76_mean"])
    weights = fit(train, selected["stage"], selected["degree"], selected["context"])
    model = {**selected, "weights": weights.tolist(), "training_files": [s["stem"] for s in train],
             "note": "Offline response hypothesis, not an implementation of SPP algorithms."}
    # 此文件在读取留出组误差之前写出，保留模型选择边界。
    (args.output / "frozen-model.json").write_text(json.dumps(model, indent=2) + "\n")
    results = []
    for sample in samples:
        prediction = predict(sample, weights, selected["stage"], selected["degree"], selected["context"])
        baseline = original_prototype(sample)
        result = {"file": sample["stem"], "split": sample["split"], "group": sample["group"],
                  "saved_settings": asdict(sample["settings"]),
                  "baseline": measure(baseline, sample["reference"]),
                  "candidate": measure(prediction, sample["reference"])}
        results.append(result)
        for suffix, image in [("reference", sample["reference"]), ("candidate", prediction), ("baseline", baseline)]:
            pixels = np.rint(np.clip(image, 0, 1) * 255).astype(np.uint8)
            Image.fromarray(pixels).save(args.output / f"{sample['stem']}-{suffix}.png")
    summary = {}
    for split in ["train", "validation"]:
        summary[split] = {}
        for kind in ["baseline", "candidate"]:
            subset = [r for r in results if r["split"] == split]
            summary[split][kind] = {key: float(np.mean([r[kind][key] for r in subset])) for key in subset[0][kind]}
    report = {"selected": selected, "training_group_cv": candidates, "summary": summary, "images": results,
              "metric": "CIE76 after linear-light block reduction; equal weight per image, not pooled pixels."}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
