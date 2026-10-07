"""Named native-look samples and explicitly declared external reference comparison."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np

from . import __version__
from .native import read_native


INPUT_SPACE = "scene-linear-srgb-d65"
OUTPUT_SPACE = "display-srgb"
DEFAULT_SAMPLES = Path(__file__).resolve().parent.parent / "examples/look-validation/samples.json"


def _rgb(value, *, output=False):
    rgb = np.asarray(value, dtype=np.float64)
    if rgb.shape != (3,) or not np.isfinite(rgb).all() or np.any(abs(rgb) > np.finfo(np.float32).max):
        raise ValueError("RGB must contain three finite float32-range numbers")
    if output and (np.any(rgb < 0) or np.any(rgb > 1)):
        raise ValueError("Display-sRGB output must be within [0, 1]")
    return rgb


def _samples(document, input_key):
    if (not isinstance(document, dict) or document.get("schema_version") != 1
            or document.get("input_space") != INPUT_SPACE):
        raise ValueError("Unsupported sample schema or input space")
    samples = document.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError("A nonempty sample list is required")
    ids = set()
    for sample in samples:
        if not isinstance(sample, dict) or not isinstance(sample.get("id"), str) or not sample["id"]:
            raise ValueError("Each sample needs a nonempty ID")
        if sample["id"] in ids or not isinstance(sample.get("category"), str) or not sample["category"]:
            raise ValueError("Sample IDs must be unique and categories nonempty")
        ids.add(sample["id"])
        _rgb(sample.get(input_key))
    return samples


def load_samples(path=None):
    document = json.loads(Path(path or DEFAULT_SAMPLES).read_text())
    _samples(document, "rgb")
    return document


def evaluate_samples(look, probe, samples=None):
    look = Path(look)
    sample_list = _samples(samples if samples is not None else load_samples(), "rgb")
    metadata = read_native(look)["metadata"]
    inputs = np.asarray([s["rgb"] for s in sample_list], dtype="<f4")
    with tempfile.TemporaryDirectory(prefix="rawlab-samples-") as directory:
        source, destination = Path(directory) / "input.f32", Path(directory) / "output.f32"
        source.write_bytes(inputs.tobytes())
        result = subprocess.run([str(Path(probe).resolve()), "--evaluate", str(look.resolve()),
                                 str(source), str(destination)], capture_output=True, text=True, check=False)
        if result.returncode:
            raise ValueError(f"Native probe failed ({result.returncode}): {result.stderr.strip()}")
        if not destination.is_file() or destination.stat().st_size != inputs.size * 4:
            raise ValueError("Native probe output length does not match sample count")
        outputs = np.frombuffer(destination.read_bytes(), dtype="<f4").reshape(-1, 3)
        for output in outputs:
            _rgb(output, output=True)
    return {
        "schema_version": 1, "input_space": INPUT_SPACE, "output_space": OUTPUT_SPACE,
        "evaluator": {"name": "RawLab native CPU", "version": __version__, "kind": "internal"},
        "preset": {"sha256": hashlib.sha256(look.read_bytes()).hexdigest(), "metadata": metadata},
        "samples": [{"id": sample["id"], "category": sample["category"],
                     "input_rgb": inputs[index].tolist(), "output_rgb": outputs[index].tolist()}
                    for index, sample in enumerate(sample_list)],
        "reference_status": "not_supplied", "appearance": {"status": "unverified"},
    }


def _errors(values):
    return {"max": float(np.max(values)), "mean": float(np.mean(values)),
            "p99": float(np.quantile(values, .99))}


def compare_reports(actual, reference, max_error):
    if not np.isfinite(max_error) or max_error < 0:
        raise ValueError("The maximum channel-error threshold must be finite and nonnegative")
    if not isinstance(actual, dict) or not isinstance(reference, dict):
        raise ValueError("Actual and reference reports must be JSON objects")
    actual_evaluator = actual.get("evaluator")
    if (not isinstance(actual_evaluator, dict) or actual_evaluator.get("kind") != "internal"
            or actual_evaluator.get("name") != "RawLab native CPU"
            or not isinstance(actual_evaluator.get("version"), str) or not actual_evaluator["version"].strip()):
        raise ValueError("Actual report requires the declared RawLab native CPU evaluator and version")
    evaluator = reference.get("evaluator", {})
    if (not isinstance(evaluator, dict) or evaluator.get("kind") != "independent"
            or any(not isinstance(evaluator.get(key), str) or not evaluator[key].strip()
                   for key in ("name", "version", "provenance"))
            or "rawlab" in evaluator.get("name", "").lower()):
        raise ValueError("Reference requires an independent renderer name, version and provenance")
    for key in ("input_space", "output_space", "preset"):
        if key not in actual or actual[key] != reference.get(key):
            raise ValueError(f"Reference {key} does not match actual conditions")
    if (actual["output_space"] != OUTPUT_SPACE or not isinstance(actual["preset"], dict)
            or not actual["preset"].get("sha256") or not isinstance(actual["preset"].get("metadata"), dict)):
        raise ValueError("Expected display-sRGB and a declared preset identity")
    actual_samples = _samples(actual, "input_rgb")
    reference_samples = _samples(reference, "input_rgb")
    if len(actual_samples) != len(reference_samples):
        raise ValueError("Reference sample count does not match")
    errors, categories = [], {}
    for sample, expected in zip(actual_samples, reference_samples):
        if (sample["id"] != expected["id"] or sample["category"] != expected["category"]
                or not np.array_equal(np.asarray(sample["input_rgb"], dtype="<f4"),
                                      np.asarray(expected["input_rgb"], dtype="<f4"))):
            raise ValueError("Reference sample IDs, categories or float32 inputs do not match")
        error = abs(_rgb(sample.get("output_rgb"), output=True) - _rgb(expected.get("output_rgb"), output=True))
        errors.append(error)
        categories.setdefault(sample["category"], []).append(error)
    metrics = _errors(errors)
    return {"schema_version": 1, "scope": "named-sample-agreement-only",
            "status": "passed" if metrics["max"] <= max_error else "failed",
            "sample_count": len(errors), "max_error_threshold": max_error, "errors": metrics,
            "categories": {name: _errors(values) for name, values in sorted(categories.items())},
            "reference": evaluator, "camera_equivalence": "not_evaluated"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    evaluate = commands.add_parser("evaluate")
    evaluate.add_argument("look", type=Path)
    evaluate.add_argument("--probe", type=Path, required=True)
    evaluate.add_argument("--samples", type=Path)
    compare = commands.add_parser("compare")
    compare.add_argument("actual", type=Path)
    compare.add_argument("reference", type=Path)
    compare.add_argument("--max-error", type=float, required=True)
    args = parser.parse_args()
    try:
        if args.command == "evaluate":
            report = evaluate_samples(args.look, args.probe, load_samples(args.samples))
        else:
            if args.actual.resolve() == args.reference.resolve():
                raise ValueError("Actual and independent reference must be different files")
            report = compare_reports(json.loads(args.actual.read_text()), json.loads(args.reference.read_text()),
                                     args.max_error)
        print(json.dumps(report, indent=2, allow_nan=False))
        return 1 if report.get("status") == "failed" else 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(2, f"{error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
