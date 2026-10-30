"""校准数据划分、参数冻结和共同样本统计的显式约束。"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import numpy as np


def validate_training_manifest(manifest):
    if not isinstance(manifest, dict) or manifest.get("role") != "neutral-development-v2":
        raise ValueError("Expected a prepared neutral-development-v2 manifest")
    rows = manifest.get("samples", [])
    excluded = set(manifest.get("excluded_dates", []))
    if not rows or not excluded:
        raise ValueError("Training samples and excluded holdout dates must be explicit")
    if any(row.get("split") != "development" or row.get("group") in excluded for row in rows):
        raise ValueError("Training manifest includes an unclassified or holdout sample")
    return rows


def payload_hash(model):
    payload = {key: model[key] for key in ("base", "controls", "fill")}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_hashes():
    names = ("bounded_lut.py", "calibration.py", "saved_controls.py", "saved_settings.py",
             "render_v2.py", "scene_cache.py", "decode_scene.rs", "evaluate_v2.py", "evaluation_contract.py",
             "compare_corpus.py", "frozen_render.py")
    return {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in names}


def validate_frozen(model, manifest, manifest_hash, current_sources):
    freeze = model.get("freeze", {})
    if freeze.get("status") != "frozen":
        raise ValueError("Holdout evaluation requires a frozen model")
    if freeze.get("holdout_manifest_sha256") != manifest_hash:
        raise ValueError("Holdout manifest changed after model freeze")
    if freeze.get("model_payload_sha256") != payload_hash(model):
        raise ValueError("Model changed after freeze")
    if freeze.get("source_sha256") != current_sources:
        raise ValueError("Rendering or evaluation source changed after freeze")
    excluded = {row["scene_group"] for row in manifest["samples"] if row["split"] == "holdout"}
    if not excluded:
        raise ValueError("No holdout date groups are declared")
    for component in ("base", "controls", "fill"):
        dates = model[component].get("training_dates")
        if not dates or excluded.intersection(dates):
            raise ValueError(f"{component} has missing training provenance or includes a holdout date")
        manifests = model[component].get("source_manifests")
        if not manifests:
            raise ValueError(f"{component} has no recorded source manifests")
        for source in manifests:
            if hashlib.sha256(Path(source["path"]).read_bytes()).hexdigest() != source["sha256"]:
                raise ValueError(f"{component} source manifest changed")


def version_summary(rows, kind):
    measured = [row for row in rows if kind in row]
    if not measured:
        return {}
    groups = sorted({row["group"] for row in measured})
    return {"images": len(measured), "groups": len(groups),
            "image_mean_delta_e76": float(np.mean([r[kind]["delta_e76_mean"] for r in measured])),
            "group_mean_delta_e76": float(np.mean([np.mean([r[kind]["delta_e76_mean"] for r in measured if r["group"] == group]) for group in groups])),
            "image_mean_false_white_fraction": float(np.mean([r[kind]["false_white_fraction"] for r in measured]))}


def paired_summary(rows):
    paired = [row for row in rows if "v1" in row and "v2" in row]
    return {"files": [row["file"] for row in paired],
            "v1": version_summary(paired, "v1"), "v2": version_summary(paired, "v2")}


def main():
    parser = argparse.ArgumentParser(description="Freeze a reviewed calibration candidate before independent evaluation")
    for name in ("candidate", "data", "training-manifest", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Frozen output already exists")
    model = json.loads(args.candidate.read_text())
    training = json.loads(args.training_manifest.read_text())
    validate_training_manifest(training)
    training_hash = hashlib.sha256(args.training_manifest.read_bytes()).hexdigest()
    if model["base"].get("training_manifest_sha256") != training_hash:
        raise ValueError("Base model is not bound to this training manifest")
    data_path = args.data / "manifest.json"
    manifest = json.loads(data_path.read_text())
    data_hash = hashlib.sha256(data_path.read_bytes()).hexdigest()
    model["freeze"] = {"status": "frozen", "at_utc": datetime.now(timezone.utc).isoformat(),
                       "holdout_manifest_sha256": data_hash, "training_manifest_sha256": training_hash,
                       "model_payload_sha256": payload_hash(model), "source_sha256": source_hashes(),
                       "policy": "Previously viewed January 8 v1 validation images are historical development data; only the new reserved dates are independent."}
    validate_frozen(model, manifest, data_hash, source_hashes())
    model["status"] = "Frozen before independent new-date evaluation; parameters must not be selected using its results"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(model, indent=2) + "\n")
    args.output.chmod(0o444)
    print(json.dumps({"model": str(args.output), "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
                      "frozen_at_utc": model["freeze"]["at_utc"]}))


if __name__ == "__main__":
    main()
