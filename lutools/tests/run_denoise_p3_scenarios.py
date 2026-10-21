#!/usr/bin/env python3
"""Validate P3 on actual tone/LUT display buffers before native promotion."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import cv2
import numpy as np

import denoise_experiment_metrics as metrics
import denoise_p3 as p3
from run_denoise_quality import sha256, write_json


AMOUNTS = (.5, 1., 2.)
GATES = {"ordinary_max_abs": 2e-6, "common_delta_max": 3e-7,
         "equivalent_boost_relative_error": .03, "equivalent_boost_roundoff": 2e-7,
         "flat_variance_ratio": 1.02, "flat_mean_change": 1e-5,
         "flat_chroma_variance_ratio": 1.02, "flat_chroma_variance_roundoff": 1e-12,
         "hard_step_max_change": 1e-6, "halo_excess_vs_ordinary": 1e-6,
         "added_guard_delta": 1 / 255, "added_reversal_fraction": .01,
         "neutral_clean_edge_boost_relative_error": .03, "texture_projection_floor": .995}


def scenarios(root, creative):
    film = root / "flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"
    return [
        {"id": "neutral"},
        {"id": "shadow-lift", "exposure_ev": 1.5, "shadows": .5},
        {"id": "shadow-crush", "shadows": -.6, "contrast": 1.2},
        {"id": "highlight-compress", "exposure_ev": 1, "highlights": .6},
        {"id": "contrast-color", "contrast": 1.5, "saturation": 1.4, "tone_curve": .35},
        {"id": "desaturated", "saturation": 0, "tone_curve": -.3},
        {"id": "film-half", "lut": str(film), "lut_strength": .5},
        {"id": "film-full", "lut": str(film), "lut_strength": 1},
        {"id": "film-tone", "lut": str(film), "lut_strength": 1.6,
         "exposure_ev": -.7, "shadows": .4, "contrast": 1.25, "saturation": 1.3},
        {"id": "creative-half", "lut": str(creative), "lut_strength": .5},
        {"id": "creative-full", "lut": str(creative), "lut_strength": 1},
        {"id": "creative-tone", "lut": str(creative), "lut_strength": 2,
         "contrast": 1.2, "tone_curve": -.2}]


def write_creative_lut(path):
    with path.open("x") as stream:
        stream.write('# Gamma: sRGB to sRGB\n# Gamut: ITU-R BT.709 to ITU-R BT.709\nLUT_3D_SIZE 17\n')
        for blue in np.linspace(0, 1, 17):
            for green in np.linspace(0, 1, 17):
                for red in np.linspace(0, 1, 17):
                    stream.write(f"{.03 + .94 * red ** .8:.9f} {.01 + .97 * green ** 1.1:.9f} "
                                 f"{.05 + .89 * blue ** 1.3:.9f}\n")


def synthetic_cases():
    random = np.random.default_rng(20261022)
    cases = []
    for mean in (.01, .18, .8):
        for sigma in (.001, .005, .02):
            truth = np.full((256, 320, 3), mean, np.float32)
            source = truth + random.normal(0, sigma, truth.shape).astype(np.float32)
            cases.append((f"flat-{mean}-{sigma}", "flat", source, truth))
    for label, left, right in (("gray", [.03] * 3, [.7] * 3),
                                ("color", [.8, .02, .08], [.8, .6, .3])):
        step = np.full((256, 320, 3), left, np.float32)
        step[:, 160:] = right
        cases.append((f"hard-{label}", "hard", step, step))
        for blur in (1., 2.):
            truth = cv2.GaussianBlur(step, (0, 0), blur)
            for sigma in (0, .005, .02):
                source = truth + random.normal(0, sigma, truth.shape).astype(np.float32)
                cases.append((f"edge-{label}-{blur}-{sigma}", "edge", source, truth))
    yy, xx = np.indices((256, 320))
    truth = np.repeat((.18 + .04 * np.sin(xx * .5) * np.cos(yy * .3))[..., None], 3, axis=2).astype(np.float32)
    for sigma in (0, .01):
        source = truth + random.normal(0, sigma, truth.shape).astype(np.float32)
        cases.append((f"texture-{sigma}", "texture", source, truth))
    return cases


def render(probe, directory, source, settings):
    directory.mkdir()
    input_path = directory / "linear.f32"
    descriptor = metrics.write_buffer(input_path, source, "linear_sRGB", "frozen_input")
    request = {"input": {"path": str(input_path), "width": source.shape[1], "height": source.shape[0]},
               "output": str(directory / "native"), "scenarios": settings}
    write_json(directory / "request.json", request)
    result = subprocess.run([str(probe), str(directory / "request.json")], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    report_path = directory / "native/result.json"
    report = json.loads(report_path.read_text())
    validate_render_report(report, source.shape, settings, directory / "native")
    report["input_descriptor"] = descriptor
    write_json(report_path, report)
    return report


def validate_render_report(report, shape, settings, directory):
    if report.get("backend") != "Metal" or len(report.get("scenarios", [])) != len(settings):
        raise ValueError("actual display rendering incomplete")
    root = directory.resolve()
    keys = {"off", "ordinary_0.5", "ordinary_1", "ordinary_2"}
    for scenario, expected in zip(report["scenarios"], settings):
        if scenario.get("settings") != expected or set(scenario.get("buffers", {})) != keys:
            raise ValueError("display scenario/buffer mismatch")
        for key, value in scenario["buffers"].items():
            stage = "before_sharpen" if key == "off" else "ordinary_sharpen"
            if (value.get("shape") != list(shape) or value.get("dtype") != "<f4" or
                    value.get("space") != "display_RGB" or value.get("stage") != stage or
                    value.get("bytes") != int(np.prod(shape)) * 4):
                raise ValueError("display buffer layout/domain/stage mismatch")
            path = Path(value["path"]).resolve()
            if path != root / expected["id"] / (key + ".f32"):
                raise ValueError("display buffer path outside declared output")
            digest = sha256(path)
            if "sha256" in value and value["sha256"] != digest:
                raise ValueError("display buffer hash mismatch")
            value["sha256"] = digest
            metrics.load_buffer(value)


def load(scenario, key):
    return np.asarray(metrics.load_buffer(scenario["buffers"][key]))


def reuse_render(directory, source, settings):
    report = json.loads((directory / "native/result.json").read_text())
    descriptor = report["input_descriptor"]
    digest = hashlib.sha256(np.asarray(source, dtype="<f4").tobytes()).hexdigest()
    if descriptor["sha256"] != digest or [s["settings"] for s in report["scenarios"]] != settings:
        raise ValueError("reused actual-display input/settings do not match")
    if descriptor["shape"] != list(source.shape):
        raise ValueError("reused input shape does not match")
    metrics.load_buffer(descriptor)
    validate_render_report(report, source.shape, settings, directory / "native")
    return report


def edge_response(image):
    profile = metrics.luma(image[16:-16]).mean(axis=0)
    center = image.shape[1] // 2
    low, high = float(np.median(profile[center - 24:center - 16])), float(np.median(profile[center + 16:center + 24]))
    direction = 1 if high >= low else -1
    gradient = np.diff(profile) * direction
    peak = center - 8 + int(np.argmax(gradient[center - 8:center + 8]))
    normalized = (profile - low) / (high - low) if abs(high - low) > 1e-8 else None
    def crossing(level):
        for index in range(center - 24, center + 24):
            if normalized[index] <= level <= normalized[index + 1] and normalized[index + 1] > normalized[index]:
                return index + float((level - normalized[index]) / (normalized[index + 1] - normalized[index]))
        return None
    first, last = (crossing(.1), crossing(.9)) if normalized is not None else (None, None)
    return {"peak_slope": float(gradient[peak]), "peak_index": peak,
            "center_slope": float(gradient[center - 1]),
            "width_10_90": last - first if first is not None and last is not None else None}


def edge_slope(image):
    return edge_response(image)["peak_slope"]


def strength_response(source, amounts, sharpen=p3.noise_aware_sharpen):
    before = edge_slope(np.clip(source, 0, 1))
    return [(float(a), edge_slope(np.clip(sharpen(source, float(a))[0], 0, 1)) - before)
            for a in amounts]


def matched_strength(source, response, target, sharpen=p3.noise_aware_sharpen):
    mapping = p3.equivalent_strength(response, target)
    if mapping["amount"] is not None:
        actual = edge_slope(sharpen(source, mapping["amount"])[0]) - edge_slope(np.clip(source, 0, 1))
        error = abs(actual - target)
        mapping.update(remeasured_edge_boost=actual, interpolation_relative_error=error / max(abs(target), 1e-8),
                       status="MATCHED" if error <= max(GATES["equivalent_boost_roundoff"],
                           GATES["equivalent_boost_relative_error"] * abs(target)) else "INTERPOLATION_MISMATCH")
    return mapping


def edge_excursion(image, truth):
    profile = metrics.luma(image[16:-16]).mean(axis=0)
    expected = metrics.luma(truth[16:-16]).mean(axis=0)
    return float(max(0, profile.max() - expected.max(), expected.min() - profile.min()))


def added_edge_excursion(image, baseline, truth):
    profile = metrics.luma(image[16:-16]).mean(axis=0)
    original = metrics.luma(baseline[16:-16]).mean(axis=0)
    expected = metrics.luma(truth[16:-16]).mean(axis=0)
    lower, upper = np.minimum(original, expected.min()), np.maximum(original, expected.max())
    return float(max(0, np.max(profile - upper), np.max(lower - profile)))


def edge_safety(image, baseline):
    center = image.shape[1] // 2
    actual = metrics.luma(image[16:-16]).mean(axis=0)[center - 24:center + 24]
    source = metrics.luma(baseline[16:-16]).mean(axis=0)[center - 24:center + 24]
    contrast = abs(float(source[-1] - source[0]))
    direction = 1 if source[-1] >= source[0] else -1
    delta = actual - source
    guard = np.concatenate((delta[:20], delta[28:]))
    reversal = float(np.maximum(-np.diff(actual) * direction, 0).sum())
    original_reversal = float(np.maximum(-np.diff(source) * direction, 0).sum())
    return {"guard_delta_max": float(np.max(np.abs(guard))),
            "added_reversal_fraction": max(0, reversal - original_reversal) / max(contrast, 1e-6)}


def evaluate_case(name, kind, rendered, truth_rendered, sharpen=p3.noise_aware_sharpen):
    reports, figures = [], []
    for index, scenario in enumerate(rendered["scenarios"]):
        context = scenario["settings"]["id"]
        source = load(scenario, "off")
        truth = load(truth_rendered["scenarios"][index], "off") if truth_rendered else None
        clipped = np.clip(source, 0, 1)
        off, _ = sharpen(source, 0)
        row = {"id": context, "checks": {"zero_exact": bool(np.array_equal(off, source))}, "methods": {}}
        interior = np.s_[16:-16, 16:-16]
        for amount in AMOUNTS:
            ordinary = load(scenario, f"ordinary_{amount:g}")
            candidate, diagnostic = sharpen(source, amount)
            delta = candidate - clipped
            common_error = float(np.max(np.ptp(delta, axis=2)))
            parity = float(np.max(np.abs(ordinary - p3.ordinary_sharpen(source, amount))))
            checks = {"ordinary_parity": parity <= GATES["ordinary_max_abs"],
                      "finite_bounded": bool(np.isfinite(candidate).all() and candidate.min() >= 0 and candidate.max() <= 1),
                      "chroma_safe": common_error <= GATES["common_delta_max"]}
            measured = {"native_ordinary_max_abs": parity, "common_delta_max": common_error,
                        "diagnostics": diagnostic, "metrics": metrics.measure(candidate[interior],
                            truth[interior] if truth is not None else clipped[interior])}
            measured["metrics"]["reference_kind"] = "known_synthetic_display_signal" if truth is not None else "baseline_sharpen_off_no_gt"
            if kind == "flat":
                before = float(np.var(metrics.luma(clipped[interior])))
                ratio = float(np.var(metrics.luma(candidate[interior])) / max(before, 1e-20))
                bias = float(np.max(np.abs((candidate[interior] - clipped[interior]).mean(axis=(0, 1)))))
                checks.update(flat_variance=ratio <= GATES["flat_variance_ratio"], flat_mean=bias <= GATES["flat_mean_change"])
                chroma_before = float(np.mean(np.var(metrics.chroma(clipped[interior]), axis=(0, 1))))
                chroma_after = float(np.mean(np.var(metrics.chroma(candidate[interior]), axis=(0, 1))))
                checks["flat_chroma_variance"] = chroma_after <= chroma_before * GATES["flat_chroma_variance_ratio"] + GATES["flat_chroma_variance_roundoff"]
                measured.update(variance_ratio=ratio, mean_change=bias,
                                chroma_variance_before=chroma_before, chroma_variance_after=chroma_after)
            if kind == "hard":
                change = float(np.max(np.abs(candidate - clipped)))
                checks["hard_step_unchanged"] = change <= GATES["hard_step_max_change"]
                measured["hard_step_max_change"] = change
            if kind in ("edge", "hard"):
                excursion = edge_excursion(candidate, np.clip(truth, 0, 1))
                reference_excursion = edge_excursion(ordinary, np.clip(truth, 0, 1))
                added = added_edge_excursion(candidate, clipped, np.clip(truth, 0, 1))
                ordinary_added = added_edge_excursion(ordinary, clipped, np.clip(truth, 0, 1))
                checks["halo_not_worse_than_ordinary"] = added <= ordinary_added + GATES["halo_excess_vs_ordinary"]
                safety = edge_safety(candidate, clipped)
                checks.update(guard_delta_bounded=safety["guard_delta_max"] <= GATES["added_guard_delta"],
                              no_new_edge_ringing=safety["added_reversal_fraction"] <= GATES["added_reversal_fraction"])
                measured.update(halo_excursion=excursion, ordinary_halo_excursion=reference_excursion,
                                added_halo_excursion=added, ordinary_added_halo_excursion=ordinary_added,
                                legacy_halo_check=excursion <= reference_excursion + GATES["halo_excess_vs_ordinary"],
                                edge_safety=safety,
                                edge_response=edge_response(candidate), off_edge_response=edge_response(clipped),
                                ordinary_edge_response=edge_response(ordinary),
                                edge_profile=metrics.edge_profile_metrics(candidate, np.clip(truth, 0, 1), source.shape[1] // 2))
                if context == "neutral" and name.startswith("edge-gray-") and name.endswith("-0"):
                    boost = edge_slope(ordinary) - edge_slope(clipped)
                    error = abs(edge_slope(candidate) - edge_slope(ordinary)) / max(abs(boost), 1e-8)
                    checks["clean_gray_strength"] = error <= GATES["neutral_clean_edge_boost_relative_error"]
                    measured["edge_boost_relative_error"] = error
            if kind == "texture" and name == "texture-0":
                high, baseline = metrics.detail(candidate[interior]), metrics.detail(clipped[interior])
                projection = float(np.mean(high * baseline) / max(float(np.mean(baseline * baseline)), 1e-20))
                checks["texture_not_weakened"] = projection >= GATES["texture_projection_floor"]
                measured["detail_projection_to_off"] = projection
            row["methods"][f"p3_{amount:g}"] = {**measured, "checks": checks}
            if amount == 1 and context in ("neutral", "film-tone", "creative-tone", "contrast-color"):
                h, w = source.shape[:2]
                crop = np.s_[max(0, h // 2 - 96):h // 2 + 96, max(0, w // 2 - 96):w // 2 + 96]
                figures.append((context, [clipped[crop], ordinary[crop], candidate[crop]]))
        if kind == "edge":
            before = edge_slope(clipped)
            sweep = strength_response(source, np.linspace(0, 2, 17), sharpen)
            monotonic = all(b[1] >= a[1] - 1e-7 for a, b in zip(sweep, sweep[1:]))
            row["checks"]["monotonic_edge_response"] = monotonic
            row["strength_response"] = sweep
            row["ordinary_equivalents"] = {}
            for amount in AMOUNTS:
                target = edge_slope(load(scenario, f"ordinary_{amount:g}")) - before
                if monotonic and target >= 0 and all(b[1] >= a[1] for a, b in zip(sweep, sweep[1:])):
                    mapping = matched_strength(source, sweep, target, sharpen)
                else:
                    mapping = {"status": "NONMONOTONIC_OR_NONPOSITIVE", "amount": None}
                row["ordinary_equivalents"][f"{amount:g}"] = {"target_edge_boost": target, **mapping}
            row["checks"]["equivalent_interpolation_verified"] = all(
                mapping["status"] != "INTERPOLATION_MISMATCH" for mapping in row["ordinary_equivalents"].values())
        reports.append(row)
    return reports, figures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display-probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous", type=Path, help="Previous frozen native-filtered linear RGB measurement ROI directory")
    parser.add_argument("--reuse-native", type=Path, help="Re-evaluate verified actual-display buffers without rendering again")
    args = parser.parse_args()
    cv2.setNumThreads(6)
    args.output.mkdir(parents=True, exist_ok=False)
    creative = args.output / "creative-control.cube"
    write_creative_lut(creative)
    settings = scenarios(Path(__file__).resolve().parents[1], creative)
    if args.reuse_native:
        prior = json.loads((args.reuse_native / "frozen-plan.json").read_text())
        for path, digest in prior["lut_sha256"].items():
            if sha256(Path(path)) != digest:
                raise ValueError("reused LUT changed")
        expected = [{**s, **({"lut": sha256(Path(s["lut"]))} if "lut" in s else {})} for s in settings]
        actual = [{**s, **({"lut": sha256(Path(s["lut"]))} if "lut" in s else {})} for s in prior["scenarios"]]
        if expected != actual or sha256(args.display_probe) != prior["probe_sha256"]:
            raise ValueError("reused renderer/settings do not match")
        settings = prior["scenarios"]
    cases = synthetic_cases()
    provenance = []
    if args.previous:
        for path in sorted((args.previous / "ai").glob("*/measurement-crops.npz")):
            provenance.append({"path": str(path), "sha256": sha256(path)})
            with np.load(path) as saved:
                for key in saved.files:
                    if key.endswith(("__SWT v2", "__SWT v1", "__C5 v2")):
                        name = path.parent.name + "-" + key.split("__")[0]
                        cases.append((name, "real_roi", saved[key].copy(), None))
    write_json(args.output / "frozen-plan.json", {"candidate": p3.CANDIDATE_ID, "gates": GATES,
        "halo_reference": "pointwise envelope of sharpen-off profile and synthetic truth extrema; original absolute metric retained",
        "strength_semantics": p3.STRENGTH_SEMANTICS + "; ordinary equivalence is contextual and may be unreachable",
        "cases": [{"id": name, "kind": kind, "shape": list(source.shape)} for name, kind, source, _ in cases],
        "scenarios": settings, "real_roi_sources": provenance,
        "probe_sha256": sha256(args.display_probe), "candidate_sha256": sha256(Path(p3.__file__)),
        "reused_native": str(args.reuse_native) if args.reuse_native else None,
        "lut_sha256": {s["lut"]: sha256(Path(s["lut"])) for s in settings if "lut" in s}})
    reports, failures = [], []
    for name, kind, source, truth in cases:
        directory = args.output / name
        directory.mkdir()
        if args.reuse_native:
            rendered = reuse_render(args.reuse_native / name / "source", source, settings)
            reference = reuse_render(args.reuse_native / name / "truth", truth, settings) if truth is not None else None
        else:
            rendered = render(args.display_probe, directory / "source", source, settings)
            reference = render(args.display_probe, directory / "truth", truth, settings) if truth is not None else None
        rows, figures = evaluate_case(name, kind, rendered, reference)
        write_json(directory / "result.json", {"kind": kind, "scenarios": rows})
        for row in rows:
            for check, passed in row["checks"].items():
                if not passed:
                    failures.append([name, row["id"], check])
            for method, measured in row["methods"].items():
                for check, passed in measured["checks"].items():
                    if not passed:
                        failures.append([name, row["id"], method, check])
        if kind == "real_roi" or name in ("edge-color-1.0-0", "edge-gray-2.0-0.005", "flat-0.18-0.005", "texture-0"):
            metrics.save_comparison(directory / "comparison.png", figures, ["Sharpen off", "Ordinary 1", "P3 1"],
                display=True, subtitle=name + " | actual Metal tone/LUT input | nominal gain, not universal equal strength")
        reports.append({"id": name, "kind": kind, "result": str(directory / "result.json")})
        print(name, "MEASURED", flush=True)
    write_json(args.output / "results.json", {"status": "PASSED" if not failures else "FAILED_GATES",
        "candidate": p3.CANDIDATE_ID, "cases": reports, "failures": failures,
        "limits": ["Real RAW checks use retained measurement ROIs, not full-frame P3 noise-estimator context.",
                   "Real ROI reference is sharpen-off, not clean ground truth.",
                   "Tone/LUT rendering is actual Metal; no native P3 implementation or CPU float rendering is implied."]})
    print(json.dumps({"cases": len(reports), "failures": len(failures)}))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
