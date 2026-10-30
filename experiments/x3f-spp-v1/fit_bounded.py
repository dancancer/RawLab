"""只用开发日期的中性参考选择并冻结有界基础颜色映射。"""

import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from bounded_lut import compress_scene, fit, interpolate, monotone_prior
from calibration import measure
from evaluation_contract import validate_training_manifest


def training_points(samples):
    group_counts = {group: sum(s["group"] == group for s in samples)
                    for group in {s["group"] for s in samples}}
    xs, ys, ws = [], [], []
    for sample in samples:
        x = sample["input"].reshape(-1, 3)[::31]
        y = sample["reference"].reshape(-1, 3)[::31]
        xs.append(x); ys.append(y)
        ws.append(np.full(len(x), 1 / (len(x) * group_counts[sample["group"]])))
    return np.concatenate(xs), np.concatenate(ys), np.concatenate(ws)


def train(samples, size, smoothness):
    axis = np.concatenate(([-0.25], np.linspace(0, 0.98, size - 1)))
    x, y, weight = training_points(samples)
    prior = monotone_prior(x, y, weight, axis)
    nodes = fit(x, y, axis, weight, smoothness, prior)
    return axis, nodes


def score(samples, axis, nodes):
    rows = []
    for sample in samples:
        actual = interpolate(sample["input"], axis, nodes).reshape(sample["reference"].shape)
        metrics = measure(actual, sample["reference"])
        metrics["false_white_fraction"] = float(np.mean(np.all(actual > .995, axis=-1)
                                                        & np.any(sample["reference"] < .97, axis=-1)))
        rows.append({"name": sample["name"], "group": sample["group"], **metrics})
    groups = sorted({row["group"] for row in rows})
    group_mean = np.mean([np.mean([r["delta_e76_mean"] for r in rows if r["group"] == group]) for group in groups])
    return float(group_mean), rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.data / "manifest.json").read_text())
    samples = []
    for row in validate_training_manifest(manifest):
        if hashlib.sha256(Path(row["path"]).read_bytes()).hexdigest() != row["array_sha256"]:
            raise ValueError("Prepared training arrays changed after their manifest was recorded")
        image = np.load(row["path"])
        samples.append({**row, "input": compress_scene(image["scene"]), "reference": image["reference"]})
    groups = sorted({s["group"] for s in samples})
    if len(groups) < 4:
        raise ValueError("At least four development date groups are required")
    fold_for_group = {group: index % 4 for index, group in enumerate(groups)}
    candidates = []
    for size in (7, 9, 11):
        for smoothness in (0.0001, 0.001, 0.01):
            rows = []
            for fold in range(4):
                training = [s for s in samples if fold_for_group[s["group"]] != fold]
                held = [s for s in samples if fold_for_group[s["group"]] == fold]
                axis, nodes = train(training, size, smoothness)
                _, scores = score(held, axis, nodes)
                rows.extend(scores)
            group_mean = float(np.mean([np.mean([r["delta_e76_mean"] for r in rows if r["group"] == group]) for group in groups]))
            candidate = {"size": size, "smoothness": smoothness, "date_group_cv_mean_delta_e76": group_mean,
                         "mean_false_white_fraction": float(np.mean([r["false_white_fraction"] for r in rows])), "images": rows}
            candidates.append(candidate)
            print(json.dumps({key: value for key, value in candidate.items() if key != "images"}), flush=True)
    selected = min(candidates, key=lambda candidate: candidate["date_group_cv_mean_delta_e76"])
    axis, nodes = train(samples, selected["size"], selected["smoothness"])
    args.output.mkdir(parents=True, exist_ok=True)
    model = {"type": "bounded-trilinear-neutral-v2", "input_compression": "signed_srgb_abs_over_one_plus_abs",
             "axis": axis.tolist(), "nodes": nodes.tolist(), "selected": {k: v for k, v in selected.items() if k != "images"},
             "training_files": [s["name"] for s in samples], "training_dates": groups,
             "training_manifest_sha256": hashlib.sha256((args.data / "manifest.json").read_bytes()).hexdigest(),
             "note": "Neutral DP1S display response, not an official SPP algorithm. No new-date holdout data used."}
    (args.output / "frozen-base-model.json").write_text(json.dumps(model, indent=2) + "\n")
    report = {"fold_for_group": fold_for_group, "candidates": candidates, "selected": model["selected"]}
    (args.output / "base-cv-report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
