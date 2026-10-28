#!/usr/bin/env python3
"""Run one opt-in fixed-weight AI or independent display-domain P3 experiment."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import resource
import sys
import time

import cv2
import numpy as np

import denoise_ai_adapter as ai
import denoise_experiment_metrics as metrics
import denoise_p3 as p3
from run_denoise_quality import sha256, validate_manifest, write_json


def native_label(native):
    stage = native["experiment"]["buffers"]["swt"]["stage"]
    labels = {"frozen_swt_v2": "SWT v2", "frozen_swt_legacy": "SWT v1", "frozen_c5_v2": "C5 v2"}
    if stage not in labels:
        raise ValueError("unknown frozen native denoiser stage")
    return labels[stage]


def selected_figures(directory, case, images, reference=None, display=False, figure_labels=None):
    rows, measurements, crops, full_crops = [], [], {}, {}
    shown_labels = list(images) if figure_labels is None else list(figure_labels)
    for region in case["regions"]:
        rectangle = metrics.pixel_rect(next(iter(images.values())), region)
        samples = {name: metrics.crop(image, rectangle) for name, image in images.items()}
        ref = metrics.crop(reference, rectangle) if reference is not None else None
        full_crops.update({f"{region['id']}__{name}": sample.copy() for name, sample in samples.items()})
        if ref is not None:
            full_crops[f"{region['id']}__reference"] = ref.copy()
        measurements.append({"id": region["id"], "kind": region["kind"], "rect_pixels": rectangle,
                             "methods": {name: metrics.measure(image, ref) for name, image in samples.items()}})
        x, y, width, height = rectangle
        w, h = min(width, 192), min(height, 192)
        shown = (x + (width - w) // 2, y + (height - h) // 2, w, h)
        row = []
        if reference is not None:
            value = metrics.crop(reference, shown).copy()
            row.append(value)
            crops[f"{region['id']}__reference"] = value
        for name in shown_labels:
            image = images[name]
            value = metrics.crop(image, shown).copy()
            row.append(value)
            crops[f"{region['id']}__{name}"] = value
        rows.append((region["id"] + f"  ({shown[0]}, {shown[1]}, {w}, {h})", row))
    reference_label = "ISO200 native control" if case["id"] == "sony-a7iv-200" else "Registered low ISO"
    labels = ([reference_label] if reference is not None else []) + shown_labels
    subtitle = f"{case['id']} | {'actual display RGB' if display else 'linear RGB, sRGB view'} | 1:1 crops"
    if reference is not None:
        subtitle += " | reference is not clean ground truth"
    metrics.save_comparison(directory / "comparison.png", rows, labels, display=display,
                            view_ev=case.get("view_ev", 0), subtitle=subtitle)
    if not display and case["id"] == "sony-a7cii-dsc06251":
        metrics.save_comparison(directory / "comparison-minus2ev.png", rows, labels, view_ev=-2,
                                subtitle=subtitle + " | all columns -2EV")
    np.savez_compressed(directory / "selected-crops.npz", **crops)
    np.savez_compressed(directory / "measurement-crops.npz", **full_crops)
    return measurements


def run_ai(directory, case, native, model_directory, linear=False):
    buffers, sensor = native["experiment"]["buffers"], native["experiment"]["sensor"]
    source, swt = metrics.load_buffer(buffers["source"]), metrics.load_buffer(buffers["swt"])
    if sensor["status"] != "EXPORTED_BAYER":
        raise ValueError("this Bayer adapter experiment requires an exported Bayer input")
    mosaic = metrics.load_buffer(sensor["buffer"])
    packed, offset = ai.pack_bayer(mosaic, sensor)
    session, name, model = ai.model_session(model_directory, "bayer")
    start = time.perf_counter()
    network = ai.tiled_inference(packed, lambda tile: session.run(None, {name: tile[None]})[0][0],
                                 scale=2, output_path=directory / "network-camera.f32")
    inference_seconds = time.perf_counter() - start
    source_sensor = ai.sensor_view(source, sensor["flip"])
    variants, gains = {}, {}
    for method, label in (("plane_mean", "AI plane mean"), ("camera_rgb_mean", "AI RGB mean")):
        scaled, gain = ai.match_input_gain(network, ai.input_anchor(packed, method))
        rgb = ai.camera_to_native(scaled, sensor)
        candidate = source_sensor.copy()
        y, x = offset
        candidate[y:y + rgb.shape[0], x:x + rgb.shape[1]] = rgb
        oriented = ai.orient(candidate, sensor["flip"])
        variants[label] = metrics.write_buffer(directory / f"{method}.f32", oriented, "linear_sRGB", method)
        gains[method] = gain
        del scaled, rgb, candidate, oriented
    unpacked, _ = ai.pack_bayer(mosaic, sensor, clip=False)
    mask = ai.orient(ai.clipped_input_weight(unpacked, source_sensor.shape[:2], offset), sensor["flip"])
    balanced = metrics.load_buffer(variants["AI RGB mean"])
    protected = ai.highlight_fallback(balanced, swt, mask)
    variants["AI + highlight"] = metrics.write_buffer(directory / "highlight.f32", protected, "linear_sRGB",
                                                      "camera_rgb_mean_with_input_clip_native_fallback")
    del balanced, protected, unpacked, network, packed
    reference = metrics.load_buffer(buffers["reference"]) if "reference" in buffers else (
        source if case["id"] == "sony-a7iv-200" else None)
    images = {"Native off": source, native_label(native): swt}
    images.update({label: metrics.load_buffer(descriptor) for label, descriptor in variants.items()})
    result = {
        "model": model, "bayer_inference_seconds": inference_seconds,
        "tile": 512, "halo": 64, "gains": gains, "variants": variants,
        "normalization": "signed_model_space_scale_from_input_mean_not_physical_exposure",
        "input_highlight_weight_fraction": float(np.mean(mask > .001)),
        "input_highlight_saturated_fraction": float(np.mean(mask == 1)),
        "reference_kind": "low_ISO_native_self_control_not_clean_truth" if case["id"] == "sony-a7iv-200" else native["reference_kind"],
        "regions": selected_figures(directory, case, images, reference),
        "limits": [
            "Input-anchored scalar gain is not calibrated camera exposure.",
            "The frozen Bayer model takes un-white-balanced CFA; native as-shot WB is applied after inference.",
            f"Native highlight fallback preserves {native_label(native)} in input-clipped regions; it is not learned highlight reconstruction.",
            "Low-ISO reference is approximate; new development holdouts have unknown model-training overlap.",
            "CPU FP32 prototype only; no neural GPU or production integration."
        ]}
    if linear:
        del images
        working = ai.linear_to_rec2020(source)
        session, name, contract = ai.model_session(model_directory, "linear")
        linear_variants, timings = {}, {}
        for policy in ("extended_float", "bounded_uint16"):
            inputs = working if policy == "extended_float" else np.rint(np.clip(working, 0, 1) * 65535) / 65535
            start = time.perf_counter()
            output = ai.tiled_inference(inputs.transpose(2, 0, 1),
                lambda tile: session.run(None, {name: tile[None]})[0][0], output_path=directory / f"linear-network-{policy}.f32")
            scaled, gain = ai.match_input_gain(output, float(inputs.mean(dtype=np.float64)))
            candidate = ai.rec2020_to_linear(scaled)
            timings[policy] = {"seconds": time.perf_counter() - start, "gain": gain}
            linear_variants[policy] = metrics.write_buffer(directory / f"linear-{policy}.f32", candidate,
                                                           "linear_sRGB", policy)
            del output, scaled, candidate
        linear_directory = directory / "linear"
        linear_directory.mkdir()
        images = {"Native off": source, native_label(native): swt,
                  **{key: metrics.load_buffer(value) for key, value in linear_variants.items()}}
        result["linear"] = {"model": contract, "variants": linear_variants, "timings": timings,
                            "regions": selected_figures(linear_directory, case, images, reference),
                            "limit": "Only range/quantization is varied; this does not reproduce rawpy's complete demosaic/WB pipeline."}
    return result


def run_p3(directory, case, native):
    experiment = native["experiment"]
    if experiment.get("display", {}).get("backend") != "Metal":
        raise ValueError("actual Metal pre-sharpen display buffers were not reached")
    source = metrics.load_buffer(experiment["buffers"]["display"])
    images, variants, measurements = {"Sharpen off": source}, {}, {}
    for amount, suffix in ((.5, "05"), (1, "1"), (2, "2")):
        native_sharp = metrics.load_buffer(experiment["buffers"][f"display_sharp_{suffix}"])
        ordinary = p3.ordinary_sharpen(source, amount)
        maximum = max(float(np.max(np.abs(ordinary[y:y + 128] - native_sharp[y:y + 128])))
                      for y in range(0, source.shape[0], 128))
        if maximum > 2e-6:
            raise ValueError(f"Python ordinary sharpen does not reproduce actual native display stage: {maximum}")
        del ordinary
        start = time.perf_counter()
        candidate, diagnostics = p3.noise_aware_sharpen(source, amount)
        elapsed = time.perf_counter() - start
        label = f"P3 {amount:g}"
        variants[label] = metrics.write_buffer(directory / f"p3-{suffix}.f32", candidate,
                                                "display_RGB", "test_only_noise_aware_sharpen")
        measurements[label] = {"seconds": elapsed, "diagnostics": diagnostics,
                                "ordinary_native_max_abs": maximum}
        del candidate
        images[f"Native sharpen {amount:g}"] = native_sharp
        images[label] = metrics.load_buffer(variants[label])
    return {"variants": variants, "timings_and_parity": measurements,
            "regions": selected_figures(directory, case, images, display=True,
                                        figure_labels=["Sharpen off", "Native sharpen 1", "P3 1"]),
            "limits": [f"P3 consumes only frozen {native_label(native)} display RGB, never AI output.",
                       "Neutral actual display pipeline, not every LUT/tone configuration.",
                       "CPU Python prototype timings are not optimized GPU-product timings.",
                       "Unpaired real-image variation is not a noise or detail quality score."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument("--mode", choices=("ai", "p3"), required=True)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--linear", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cv2.setNumThreads(6)
    try:
        document = json.loads(args.native.read_text())
        cases = validate_manifest(document["manifest"])
        case = next(case for case in cases if case["id"] == args.case)
        runs = [run for run in document["runs"] if run["id"] == args.case and run["preset"] == "clean"]
        if len(runs) != 1 or runs[0]["status"] != "MEASURED":
            raise ValueError("requires one successful frozen clean native export")
        native = runs[0]["result"]
        identity = native["experiment"]["processing"]
        if identity not in ({"family": "rawlab", "version": 1, "quality": "standard"},
                            {"family": "rawlab", "version": 2, "quality": "standard"}):
            raise ValueError("unexpected processing baseline")
        label = native_label(native)
        if (identity["version"] == 1) != (label == "SWT v1"):
            raise ValueError("frozen stage does not match processing identity")
        if args.mode == "ai" and not args.model_dir:
            raise ValueError("--model-dir is required for AI")
        args.output.mkdir(parents=True, exist_ok=False)
        start = time.perf_counter()
        result = run_ai(args.output, case, native, args.model_dir, args.linear) if args.mode == "ai" else run_p3(args.output, case, native)
        report = {"status": "MEASURED_NOT_PROMOTED", "quality_verdict": "NOT_EVALUATED", "mode": args.mode,
                  "created_utc": datetime.now(timezone.utc).isoformat(), "case": case,
                  "native_report_sha256": sha256(args.native), "native_probe_sha256": document["probe_sha256"],
                  "source_fingerprint": native["source_fingerprint"], "native_filtered_fingerprint": native["output_fingerprint"],
                  "processing": identity, "native_denoiser": label,
                  "source_sha256": native["experiment"]["buffers"]["source"]["sha256"],
                  "native_filtered_sha256": native["experiment"]["buffers"]["swt"]["sha256"],
                  "elapsed_seconds": time.perf_counter() - start,
                  "process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024),
                  "result": result}
        write_json(args.output / "result.json", report)
        print(f"{args.case} {args.mode}: MEASURED_NOT_PROMOTED", flush=True)
        return 0
    except (ValueError, KeyError, StopIteration, OSError) as error:
        print(f"EXPERIMENT_FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
