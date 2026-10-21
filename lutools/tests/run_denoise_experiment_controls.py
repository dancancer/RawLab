#!/usr/bin/env python3
"""Known-signal controls, separate from real RAW and from product acceptance."""

import argparse
import json
from pathlib import Path
import time

import cv2
import numpy as np

import denoise_ai_adapter as ai
import denoise_experiment_metrics as metrics
import denoise_p3 as p3
from run_denoise_quality import write_json


def p3_controls(directory):
    random = np.random.default_rng(20261021)
    cases = []
    for mean in (.08, .4, .85):
        for sigma in (.002, .01, .03):
            truth = np.full((256, 320, 3), mean, dtype=np.float32)
            source = truth + random.normal(0, sigma, truth.shape).astype(np.float32)
            cases.append((f"flat-{mean}-{sigma}", "flat", source, truth))
    step = np.full((256, 320, 3), .2, dtype=np.float32)
    step[:, 160:] = .7
    cases.append(("hard-step", "step", step, step))
    blurred = cv2.GaussianBlur(step, (0, 0), 1.5)
    for sigma in (0, .005, .02):
        source = blurred + random.normal(0, sigma, blurred.shape).astype(np.float32)
        cases.append((f"blurred-step-{sigma}", "blurred_step", source, blurred))
    yy, xx = np.indices((256, 320))
    texture = np.repeat((.3 + .025 * np.sin(xx * .7) * np.cos(yy * .5))[..., None], 3, axis=2).astype(np.float32)
    for sigma in (0, .005, .02):
        source = texture + random.normal(0, sigma, texture.shape).astype(np.float32)
        cases.append((f"texture-{sigma}", "texture", source, texture))
    reports, figures = [], []
    for name, kind, source, truth in cases:
        source_region, truth_region = source[16:-16, 16:-16], truth[16:-16, 16:-16]
        methods = {"off": metrics.measure(source_region, truth_region)}
        before_variance = float(np.var(p3.luma(source_region)))
        before_slope = float(np.diff(p3.luma(source).mean(axis=0))[159])
        for amount in (.5, 1, 2):
            candidates = {"ordinary": p3.ordinary_sharpen(source, amount),
                          "p3": p3.noise_aware_sharpen(source, amount)[0]}
            for label, candidate in candidates.items():
                row = metrics.measure(candidate[16:-16, 16:-16], truth_region)
                row["luma_variance_ratio_to_off"] = float(np.var(p3.luma(candidate[16:-16, 16:-16])) / before_variance)
                row["edge_slope_ratio_to_off"] = float(np.diff(p3.luma(candidate).mean(axis=0))[159] / before_slope) if kind.endswith("step") else None
                row["overshoot"] = float(max(0, candidate.max() - truth.max()))
                row["undershoot"] = float(max(0, truth.min() - candidate.min()))
                if kind.endswith("step"):
                    row["edge_profile"] = metrics.edge_profile_metrics(candidate, truth, 160)
                methods[f"{label}_{amount:g}"] = row
            if amount == 1 and name in ("flat-0.4-0.01", "hard-step", "blurred-step-0.005", "texture-0.005"):
                figures.append((name, [source[32:224, 64:256], candidates["ordinary"][32:224, 64:256],
                                       candidates["p3"][32:224, 64:256]]))
        reports.append({"id": name, "kind": kind, "methods": methods})
    flat = [item for item in reports if item["kind"] == "flat"]
    hard = next(item for item in reports if item["id"] == "hard-step")
    gates = {
        "flat_noise_variance_at_most_1_02_of_off": all(
            item["methods"][f"p3_{a:g}"]["luma_variance_ratio_to_off"] <= 1.02 for item in flat for a in (.5, 1, 2)),
        "clean_hard_step_guard_error_le_1e_minus_6": all(
            hard["methods"][f"p3_{a:g}"]["edge_profile"]["guard_max_abs_error"] <= 1e-6 for a in (.5, 1, 2))}
    edge = next(item for item in reports if item["id"] == "blurred-step-0.005")
    matched = []
    for a in (.5, 1, 2):
        target = edge["methods"][f"ordinary_{a:g}"]["edge_slope_ratio_to_off"]
        b = min((.5, 1, 2), key=lambda value: abs(edge["methods"][f"p3_{value:g}"]["edge_slope_ratio_to_off"] - target))
        actual = edge["methods"][f"p3_{b:g}"]["edge_slope_ratio_to_off"]
        matched.append({"ordinary_strength": a, "p3_strength": b, "ordinary_edge_gain": target, "p3_edge_gain": actual,
                        "relative_gain_difference": abs(actual - target) / target, "within_3_percent": abs(actual - target) / target <= .03})
    metrics.save_comparison(directory / "p3-controls.png", figures, ["Sharpen off", "Ordinary 1", "P3 1"],
                            display=True, subtitle="Synthetic display-domain controls | 1:1 pixels | known clean signals")
    return {"cases": reports, "invariant_gates": gates, "matched_edge_comparisons": matched,
            "quality_verdict": "CONTROL_RESULTS_NOT_PRODUCT_ACCEPTANCE"}


def model_controls(directory, model_directory):
    reports, figures = [], []
    for variant in ("bayer", "linear"):
        session, name, contract = ai.model_session(model_directory, variant)
        for color in ((.005, .005, .005), (.18, .18, .18), (.7, .7, .7), (.08, .18, .4)):
            if variant == "bayer":
                source = np.broadcast_to(np.array([color[0], color[1], color[1], color[2]], dtype=np.float32)[:, None, None], (4, 128, 128))
                expected = np.broadcast_to(np.array(color, dtype=np.float32), (256, 256, 3))
                scale = 2
            else:
                source = np.broadcast_to(np.array(color, dtype=np.float32)[:, None, None], (3, 256, 256))
                expected = np.broadcast_to(np.array(color, dtype=np.float32), (256, 256, 3))
                scale = 1
            output = ai.tiled_inference(source, lambda tile: session.run(None, {name: tile[None]})[0][0], scale=scale)
            methods = {}
            for policy in (("plane_mean", "camera_rgb_mean") if variant == "bayer" else ("input_mean",)):
                anchor = ai.input_anchor(source, policy) if variant == "bayer" else float(source.mean(dtype=np.float64))
                normalized, gain = ai.match_input_gain(output, anchor)
                methods[policy] = {"gain": gain, "metrics": metrics.measure(normalized[32:-32, 32:-32], expected[32:-32, 32:-32])}
            reports.append({"variant": variant, "kind": "constant_camera_RGB" if variant == "bayer" else "constant_Rec2020",
                            "input_color": color, "model": contract, "methods": methods})
        size = 1024 if variant == "bayer" else 512
        yy, xx = np.indices((size, size))
        signal = (.18 + .02 * np.sin(xx * .7) * np.cos(yy * .5)).astype(np.float32)
        expected = np.repeat(signal[..., None], 3, axis=2)
        source = (np.stack((signal[::2, ::2], signal[::2, 1::2], signal[1::2, ::2], signal[1::2, 1::2]))
                  if variant == "bayer" else expected.transpose(2, 0, 1))
        output = ai.tiled_inference(source, lambda tile: session.run(None, {name: tile[None]})[0][0],
                                    scale=2 if variant == "bayer" else 1)
        anchor = ai.input_anchor(source, "camera_rgb_mean") if variant == "bayer" else float(source.mean(dtype=np.float64))
        normalized, gain = ai.match_input_gain(output, anchor)
        reports.append({"variant": variant, "kind": "noiseless_monochrome_texture", "model": contract, "gain": gain,
                        "metrics": metrics.measure(normalized[128:-128, 128:-128], expected[128:-128, 128:-128])})
        center = size // 2
        figures.append((variant + " noiseless texture", [expected[center - 96:center + 96, center - 96:center + 96],
                                                         normalized[center - 96:center + 96, center - 96:center + 96]]))
    metrics.save_comparison(directory / "ai-controls.png", figures, ["Known signal", "Fixed-weight output"],
                            subtitle="Synthetic input-only gain controls | no clean-reference gain fitting")
    return {"cases": reports, "limits": ["Synthetic signals diagnose adapter/model response, not real-camera generalization.",
                                        "No constant gain or model parameter is fitted from these outputs.",
                                        "Bayer values are camera RGB; linear values are Rec.2020, not calibrated display colors."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path)
    args = parser.parse_args()
    cv2.setNumThreads(6)
    args.output.mkdir(parents=True, exist_ok=False)
    start = time.perf_counter()
    report = {"status": "MEASURED_NOT_PROMOTED", "p3": p3_controls(args.output)}
    if args.model_dir:
        report["ai"] = model_controls(args.output, args.model_dir)
    report["elapsed_seconds"] = time.perf_counter() - start
    write_json(args.output / "results.json", report)
    print(json.dumps(report["p3"]["invariant_gates"]))


if __name__ == "__main__":
    main()
