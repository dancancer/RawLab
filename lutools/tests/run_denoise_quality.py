#!/usr/bin/env python3
"""Reproducible full-resolution denoise measurements; never a quality pass/fail oracle."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys


PRESETS = {
    "off": {"enabled": False, "luma": 0, "chroma": 46, "coarse": 50},
    "detail": {"enabled": True, "luma": 0, "chroma": 46, "coarse": 50},
    "clean": {"enabled": True, "luma": 10, "chroma": 72, "coarse": 100},
}
PATTERNS = {"flat", "levels", "texture", "color_edge", "gradient", "periodic", "extended"}


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}", value):
        raise ValueError(f"unsafe identifier: {value!r}")


def number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def asset_spec(asset):
    if not isinstance(asset, dict):
        raise ValueError("asset must be an object")
    path = asset.get("path")
    if not isinstance(path, str) or not path or Path(path).is_absolute() or ".." in Path(path).parts:
        raise ValueError("asset path must be relative, without traversal")
    if not isinstance(asset.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]):
        raise ValueError("asset sha256 must be a lowercase SHA-256 digest")


def registration_spec(registration):
    if not isinstance(registration, dict):
        raise ValueError("registration must be an object")
    matrix = registration.get("input_to_reference_affine")
    if (not isinstance(matrix, list) or len(matrix) != 2 or
            any(not isinstance(row, list) or len(row) != 3 or
                not all(number(value) for value in row) for row in matrix)):
        raise ValueError("registration requires a finite 2x3 affine matrix")
    determinant = matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]
    gain = registration.get("reference_to_input_gain")
    if not math.isfinite(determinant) or abs(determinant) < 1e-12 or not number(gain) or not 0 < gain <= 1000:
        raise ValueError("registration requires an invertible transform and positive bounded gain")
    if (registration.get("estimated_from") != "input_and_reference" or
            registration.get("candidate_output_used") is not False or
            not isinstance(registration.get("method"), str) or not registration["method"].strip()):
        raise ValueError("registration must describe input-only estimation, never a candidate output fit")


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or type(manifest.get("version")) is not int or manifest["version"] != 1 or not isinstance(manifest.get("cases"), list) or not manifest["cases"]:
        raise ValueError("expected nonempty version 1 manifest")
    identifiers, captures, contents, assets = set(), {}, {}, {}

    def assign_split(mapping, key, split, label):
        if key in mapping and mapping[key] != split:
            raise ValueError(f"{label} cannot cross splits: {key}")
        mapping[key] = split

    for case in manifest["cases"]:
        if not isinstance(case, dict) or not isinstance(case.get("input"), dict):
            raise ValueError("case and input must be objects")
        identifier(case["id"])
        if case["id"] in identifiers:
            raise ValueError("duplicate case id")
        identifiers.add(case["id"])
        split = case["split"]
        if split not in {"tune", "holdout"}:
            raise ValueError("split must be tune or holdout")
        identifier(case["capture_group"])
        assign_split(captures, case["capture_group"], split, "capture_group")
        content = case.get("content_group", case["capture_group"])
        identifier(content)
        assign_split(contents, content, split, "content_group")
        source = case["input"]
        if source["kind"] == "raw":
            asset_spec(source)
            assign_split(assets, source["sha256"], split, "asset")
        elif source["kind"] == "synthetic":
            if source["pattern"] not in PATTERNS:
                raise ValueError("unknown synthetic pattern")
            for name in ("width", "height", "seed"):
                value = source[name]
                if not isinstance(value, int) or isinstance(value, bool):
                    raise ValueError(f"{name} must be an integer")
                if not (0 <= value <= 2**32 - 1 if name == "seed" else 1 <= value <= 4096):
                    raise ValueError(f"{name} outside allowed range")
            for name in ("shot", "read"):
                if not number(source[name]) or not 0 <= source[name] <= 0.1:
                    raise ValueError(f"invalid {name} noise parameter")
            if 0 < source["shot"] < 1e-8:
                raise ValueError("positive shot must be >= 1e-8 to bound Poisson counts")
            identity = {key: source[key] for key in ("pattern", "width", "height", "seed", "shot", "read")}
            for name in ("shot", "read"):
                identity[name] = float(source[name]) if source[name] != 0 else 0.0
            if source["shot"] == 0 and source["read"] == 0:
                identity["seed"] = 0
            assign_split(assets, json.dumps(identity, sort_keys=True), split, "asset")
        else:
            raise ValueError("unknown input kind")
        if "reference" in case:
            reference = case["reference"]
            asset_spec(reference)
            if source["kind"] != "raw" or reference.get("registered") is not True or reference.get("exposure_matched") is not True:
                raise ValueError("RAW reference requires registered and exposure_matched declarations")
            if reference["sha256"] == source["sha256"]:
                raise ValueError("reference must not be the input itself")
            if "registration" in reference:
                registration_spec(reference["registration"])
            assign_split(assets, reference["sha256"], split, "asset")
        region_ids = set()
        if not isinstance(case.get("regions"), list) or not case["regions"]:
            raise ValueError("at least one region is required")
        for region in case["regions"]:
            if not isinstance(region, dict):
                raise ValueError("region must be an object")
            identifier(region["id"])
            if region["id"] in region_ids:
                raise ValueError("duplicate region id")
            region_ids.add(region["id"])
            rect = region["rect"]
            if not isinstance(rect, list) or len(rect) != 4 or not all(number(v) for v in rect):
                raise ValueError("invalid region rectangle")
            x, y, width, height = rect
            if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1 or y + height > 1:
                raise ValueError("region must be inside image")
        if not number(case.get("view_ev", 0)) or not -10 <= case.get("view_ev", 0) <= 10:
            raise ValueError("view_ev outside allowed range")
    return manifest["cases"]


def validate_result(result, request):
    def require(condition, message):
        if not condition:
            raise ValueError("invalid native report: " + message)

    require(isinstance(result, dict), "expected object")
    case = request["case"]
    expected = {"version": 1, "status": "MEASURED", "request_id": request["request_id"],
                "case_id": case["id"], "split": case["split"], "options": request["options"],
                "backend_requested": request["backend"],
                "bayer_demosaic_requested": request.get("bayer_demosaic", "vng")}
    for key, value in expected.items():
        require(result.get(key) == value, f"mismatched {key}")
    pipeline = result.get("pipeline")
    require(isinstance(pipeline, dict), "pipeline")
    raw_methods = {expected["bayer_demosaic_requested"], "libraw_default"}
    require(pipeline.get("demosaic") in (raw_methods if case["input"]["kind"] == "raw" else {"not_applicable"}),
            "demosaic does not match input kind and requested method")
    require(pipeline.get("reference_demosaic") in (raw_methods if "reference" in case else {"not_applicable"}),
            "reference demosaic does not match requested method")
    for key in ("source_fingerprint", "output_fingerprint"):
        require(isinstance(result.get(key), str) and re.fullmatch(r"fnv1a64-f32le:[0-9a-f]{16}", result[key]), key)
    for key in ("width", "height"):
        require(type(result.get(key)) is int and result[key] > 0, key)
        if case["input"]["kind"] == "synthetic":
            require(result[key] == case["input"][key], f"synthetic {key}")
    for key in ("decode_ms", "filter_ms"):
        require(number(result.get(key)) and result[key] >= 0, key)
    require("peak_rss_bytes" in result and (result["peak_rss_bytes"] is None or
            (number(result["peak_rss_bytes"]) and result["peak_rss_bytes"] > 0)), "peak_rss_bytes")
    details = result.get("diagnostics")
    require(isinstance(details, dict), "diagnostics")
    require(type(details.get("applied")) is bool and type(details.get("gpu_filter_used")) is bool, "backend flags")
    require(details.get("outcome") in {"disabled", "zero_strength", "small_image", "low_noise", "insufficient_samples", "applied"}, "outcome")
    require(details["applied"] == (details["outcome"] == "applied"), "applied/outcome disagreement")
    require(not details["gpu_filter_used"] or (details["applied"] and request["backend"] != "cpu"), "false GPU success")
    require(request["backend"] != "force" or not details["applied"] or details["gpu_filter_used"], "Force did not use GPU")
    estimate = details.get("estimate")
    require(isinstance(estimate, dict), "estimate")
    require(type(estimate.get("fit_available")) is bool, "fit_available")
    fitted = estimate["fit_available"]
    require(not details["applied"] or fitted, "applied without fitted model")
    fit_fields = ("relative_fit_rmse", "sample_variance_median", "fit_rmse",
                  "relative_fit_median_abs_residual", "fit_top_decile_error_fraction")
    for source, names in ((details, ("a", "b")), (estimate, fit_fields)):
        for name in names:
            require(name in source, name)
            value = source[name]
            if fitted:
                require(isinstance(value, list) and len(value) == 3 and
                        all(number(v) and v >= 0 for v in value), name)
                if name == "fit_top_decile_error_fraction":
                    require(all(v <= 1 for v in value), name)
            else:
                require(value is None, "unavailable " + name)
    fallback = estimate.get("constant_variance_fallback")
    require("constant_variance_fallback" in estimate, "constant_variance_fallback")
    require((isinstance(fallback, list) and len(fallback) == 3 and
             all(type(value) is bool for value in fallback)) if fitted else fallback is None,
            "constant_variance_fallback")
    reference_kind = "synthetic_truth" if case["input"]["kind"] == "synthetic" else (
        "declared_registered_low_noise_reference" if "reference" in case else "none")
    require(result.get("reference_kind") == reference_kind, "reference_kind")
    if result.get("reference_registration") is not None:
        registration_spec(result["reference_registration"])
    require("reference_registration" in result and result["reference_registration"] ==
            case.get("reference", {}).get("registration"), "reference_registration")
    regions = result.get("regions")
    require(isinstance(regions, list) and all(isinstance(region, dict) for region in regions), "regions")
    require([region.get("id") for region in regions] == [region["id"] for region in case["regions"]], "region identities")
    for region, requested in zip(regions, case["regions"]):
        rect = region.get("rect_pixels")
        require(isinstance(rect, list) and len(rect) == 4 and all(type(v) is int for v in rect), "pixel rectangle")
        x, y, width, height = rect
        require(x >= 0 and y >= 0 and width > 0 and height > 0 and x + width <= result["width"] and y + height <= result["height"], "pixel bounds")
        rx, ry, rw, rh = requested["rect"]
        expected_x, expected_y = math.floor(rx * result["width"]), math.floor(ry * result["height"])
        require(rect == [expected_x, expected_y,
                        min(result["width"], math.ceil((rx + rw) * result["width"])) - expected_x,
                        min(result["height"], math.ceil((ry + rh) * result["height"])) - expected_y], "region coordinates")
        for key in ("source_variation", "output_variation"):
            value = region.get(key)
            require(isinstance(value, dict) and all(number(value.get(field)) for field in ("luma_mean", "luma_stddev", "chroma_stddev")), key)
        for key in ("source_vs_reference", "output_vs_reference", "output_vs_source"):
            require(key in region, key)
            value = region[key]
            if key != "output_vs_source" and reference_kind == "none":
                require(value is None, "unpaired input cannot have reference errors")
                continue
            require(isinstance(value, dict) and all(number(value.get(field)) and value[field] >= 0 for field in ("rgb_rmse", "luma_rmse", "chroma_rmse")), key)
            bias = value.get("mean_rgb_error")
            require(isinstance(bias, list) and len(bias) == 3 and all(number(v) for v in bias), "mean_rgb_error")
            require("luma_contrast_gain" in value and (value["luma_contrast_gain"] is None or number(value["luma_contrast_gain"])), "luma_contrast_gain")
            for key in ("luma_laplacian_gain", "reference_laplacian_rms"):
                require(key in value and (value[key] is None or number(value[key])), key)
            rms, gain = value["reference_laplacian_rms"], value["luma_laplacian_gain"]
            if width < 3 or height < 3:
                require(rms is None and gain is None, "Laplacian requires a 3x3 region")
            else:
                require(rms is not None and rms >= 0, "reference_laplacian_rms")
                require((gain is not None) == (rms > 1e-10), "gain/reference structure disagreement")
    if request["cache_check"]:
        cached = result.get("cache")
        require(isinstance(cached, dict) and cached.get("output_fingerprint") == result["output_fingerprint"], "cached output")
    json.dumps(result, allow_nan=False)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_asset(asset, root):
    asset_spec(asset)
    root = root.resolve()
    path = (root / asset["path"]).resolve()
    if not path.is_relative_to(root):
        raise ValueError("asset symlink escapes asset root")
    result = {"path": asset["path"], "expected_sha256": asset["sha256"]}
    if not path.is_file():
        return {**result, "status": "MISSING"}
    digest = sha256(path)
    return {**result, "status": "VERIFIED" if digest == asset["sha256"] else "HASH_MISMATCH",
            "sha256": digest, "bytes": path.stat().st_size, "absolute_path": str(path)}


def git_output(root, *arguments):
    completed = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 else None


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--assets", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--presets", nargs="+", choices=PRESETS, default=["off", "detail", "clean"])
    parser.add_argument("--backend", choices=["cpu", "auto", "force"], default="cpu")
    parser.add_argument("--bayer-demosaic", choices=["vng", "dht"], default="vng")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--only", nargs="+")
    parser.add_argument("--cache-check", action="store_true")
    parser.add_argument("--crops", action="store_true")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        cases = validate_manifest(manifest)
        if not 1 <= args.repeat <= 20 or args.timeout <= 0:
            raise ValueError("invalid repeat or timeout")
        if args.only:
            if set(args.only) - {case["id"] for case in cases}:
                raise ValueError("unknown case in --only")
            cases = [case for case in cases if case["id"] in args.only]
        probe = args.probe.resolve(strict=True)
        args.output.mkdir(parents=True, exist_ok=False)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.error(str(error))
    root = Path(__file__).resolve().parents[2]
    report = {"version": 1, "quality_verdict": "NOT_EVALUATED", "runs": [],
              "created_utc": datetime.now(timezone.utc).isoformat(), "manifest": manifest,
              "manifest_sha256": sha256(args.manifest), "probe_sha256": sha256(probe),
              "git_head": git_output(root, "rev-parse", "HEAD"), "git_status": git_output(root, "status", "--short"),
              "platform": platform.platform(), "machine": platform.machine(), "command": sys.argv,
              "scope": "post-demosaic linear sRGB; full image estimation/filtering; no quality acceptance thresholds"}
    failed = False
    for case in cases:
        verified = {}
        try:
            if case["input"]["kind"] == "raw":
                verified["input"] = verify_asset(case["input"], args.assets)
            if "reference" in case:
                verified["reference"] = verify_asset(case["reference"], args.assets)
        except (ValueError, OSError) as error:
            verified["input"] = {"status": "ASSET_ERROR", "message": str(error)}
        for preset in args.presets:
            for repeat in range(args.repeat):
                name = f"{case['id']}-{preset}-{repeat}"
                row = {"id": case["id"], "split": case["split"], "preset": preset, "repeat": repeat,
                       "backend_requested": args.backend, "bayer_demosaic_requested": args.bayer_demosaic, "assets": verified}
                unavailable = next((item for item in verified.values() if item["status"] != "VERIFIED"), None)
                if unavailable:
                    row["status"] = unavailable["status"]
                else:
                    request = {"case": case, "options": PRESETS[preset], "backend": args.backend,
                               "bayer_demosaic": args.bayer_demosaic,
                               "cache_check": args.cache_check, "crop_prefix": str(args.output.resolve() / name) if args.crops else None,
                               "assets": {key: value["absolute_path"] for key, value in verified.items()}}
                    request["request_id"] = hashlib.sha256(json.dumps(request, sort_keys=True, allow_nan=False).encode()).hexdigest()
                    request_path, result_path = args.output / f"{name}.request.json", args.output / f"{name}.json"
                    write_json(request_path, request)
                    try:
                        command = [str(probe), str(request_path.resolve()), str(result_path.resolve())]
                        with (args.output / f"{name}.log").open("w") as log:
                            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                        row["exit_code"] = completed.returncode
                        if completed.returncode != 0:
                            row["status"] = "PROBE_FAILED"
                            if result_path.is_file():
                                row["result"] = json.loads(result_path.read_text())
                        else:
                            result = json.loads(result_path.read_text())
                            validate_result(result, request)
                            row.update(status="MEASURED", result=result)
                    except subprocess.TimeoutExpired:
                        row["status"] = "TIMEOUT"
                    except (ValueError, KeyError, OSError) as error:
                        row.update(status="REPORT_ERROR", message=str(error))
                failed |= row["status"] != "MEASURED"
                report["runs"].append(row)
                write_json(args.output / "results.json", report)
                print(f"{name}: {row['status']}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
