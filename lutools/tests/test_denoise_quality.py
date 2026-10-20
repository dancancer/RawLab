#!/usr/bin/env python3
"""Behavior checks for the external-asset denoise quality runner."""

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest
from unittest import mock


RUNNER = Path(__file__).with_name("run_denoise_quality.py")
spec = importlib.util.spec_from_file_location("denoise_quality_runner", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
PROBE = None


def synthetic(case_id="flat", split="tune", group="flat-tune"):
    return {
        "id": case_id, "split": split, "capture_group": group,
        "input": {"kind": "synthetic", "pattern": "flat", "seed": 137,
                  "width": 256, "height": 256, "shot": 0.001, "read": 0.005},
        "regions": [{"id": "center", "kind": "flat", "rect": [0.25, 0.25, 0.5, 0.5]}],
    }


def registered_raw():
    case = synthetic()
    case["input"] = {"kind": "raw", "path": "input.arw", "sha256": "a" * 64}
    case["reference"] = {
        "path": "reference.arw", "sha256": "b" * 64,
        "registered": True, "exposure_matched": True,
        "registration": {
            "input_to_reference_affine": [[1, 0, -5.25], [0, 1, .75]],
            "reference_to_input_gain": 1.05,
            "estimated_from": "input_and_reference",
            "method": "OpenCV affine ECC",
            "candidate_output_used": False,
        },
    }
    return case


class ManifestTests(unittest.TestCase):
    def validate(self, cases):
        return runner.validate_manifest({"version": 1, "cases": cases})

    def test_checked_in_manifests_obey_schema_and_split_rules(self):
        fixtures = Path(__file__).with_name("fixtures")
        for name in ("denoise-synthetic.json", "denoise-raw-local.json", "denoise-dark-local.json",
                     "denoise-holdout-local.json"):
            with self.subTest(name=name):
                self.assertTrue(runner.validate_manifest(json.loads((fixtures / name).read_text())))

    def test_accepts_disjoint_captures(self):
        hold = synthetic("hold", "holdout", "flat-hold")
        hold["input"]["seed"] = 999
        self.assertEqual(len(self.validate([synthetic(), hold])), 2)

    def test_identical_synthetic_input_cannot_cross_splits(self):
        with self.assertRaisesRegex(ValueError, "asset.*split"):
            self.validate([synthetic(), synthetic("hold", "holdout", "different-name")])

    def test_zero_noise_seed_and_numeric_spelling_cannot_hide_identical_content(self):
        first, second = synthetic(), synthetic("hold", "holdout", "different-name")
        for case in (first, second):
            case["input"].update(shot=0, read=0)
        second["input"].update(seed=999, shot=0.0, read=0.0)
        with self.assertRaisesRegex(ValueError, "asset.*split"):
            self.validate([first, second])
        for field in ("shot", "read"):
            second["input"][field] = -0.0
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "asset.*split"):
                self.validate([first, second])
            second["input"][field] = 0.0

    def test_rejects_capture_leakage_before_filtering(self):
        with self.assertRaisesRegex(ValueError, "capture_group"):
            self.validate([synthetic(), synthetic("hold", "holdout", "flat-tune")])

    def test_same_scene_cannot_cross_splits_via_different_cameras(self):
        first, second = synthetic(), synthetic("hold", "holdout", "second-camera")
        first["input"] = {"kind": "raw", "path": "first.arw", "sha256": "a" * 64}
        second["input"] = {"kind": "raw", "path": "second.raf", "sha256": "b" * 64}
        first["content_group"] = second["content_group"] = "same-test-chart"
        with self.assertRaisesRegex(ValueError, "content_group"):
            self.validate([first, second])
        second["content_group"] = "independent-scene"
        self.assertEqual(len(self.validate([first, second])), 2)

    def test_invalid_content_group_cannot_silently_disable_scene_check(self):
        for value in (None, "", 123, ["scene"]):
            case = synthetic()
            case["content_group"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.validate([case])

    def test_rejects_renamed_asset_across_splits(self):
        cases = [synthetic(), synthetic("hold", "holdout", "different-name")]
        for index, case in enumerate(cases):
            case["input"] = {"kind": "raw", "path": f"copy-{index}.arw", "sha256": "a" * 64}
        with self.assertRaisesRegex(ValueError, "asset.*split"):
            self.validate(cases)

    def test_reference_cannot_leak_into_other_split(self):
        cases = [synthetic(), synthetic("hold", "holdout", "different-name")]
        cases[0]["input"] = {"kind": "raw", "path": "input.arw", "sha256": "a" * 64}
        cases[0]["reference"] = {"path": "reference.arw", "sha256": "b" * 64,
                                  "registered": True, "exposure_matched": True}
        cases[1]["input"] = {"kind": "raw", "path": "copy.arw", "sha256": "b" * 64}
        with self.assertRaisesRegex(ValueError, "asset.*split"):
            self.validate(cases)

    def test_reference_requires_explicit_registration_and_exposure_match(self):
        case = synthetic()
        case["input"] = {"kind": "raw", "path": "input.arw", "sha256": "a" * 64}
        case["reference"] = {"path": "reference.arw", "sha256": "b" * 64}
        with self.assertRaisesRegex(ValueError, "registered|exposure_matched"):
            self.validate([case])

    def test_reference_registration_is_input_only_and_well_formed(self):
        self.assertEqual(len(self.validate([registered_raw()])), 1)
        invalid = [
            ("input_to_reference_affine", [[1, 0, 0], [0, 0, 0]]),
            ("input_to_reference_affine", [[True, 0, 0], [0, 1, 0]]),
            ("input_to_reference_affine", [[1, 0, float("inf")], [0, 1, 0]]),
            ("input_to_reference_affine", [1, 0, 0, 0, 1, 0]),
            ("reference_to_input_gain", 0),
            ("reference_to_input_gain", -1),
            ("reference_to_input_gain", float("nan")),
            ("estimated_from", "candidate_output"),
            ("candidate_output_used", True),
            ("candidate_output_used", 0),
            ("method", ""),
        ]
        for key, value in invalid:
            case = registered_raw()
            case["reference"]["registration"][key] = value
            with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, "registration"):
                self.validate([case])
        for value in (None, [], {}):
            case = registered_raw()
            case["reference"]["registration"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "registration"):
                self.validate([case])

    def test_rejects_duplicate_case_and_region_ids(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.validate([synthetic(), synthetic()])
        case = synthetic()
        case["regions"].append(case["regions"][0].copy())
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.validate([case])

    def test_rejects_path_traversal_and_unsafe_output_id(self):
        case = synthetic("../escape")
        with self.assertRaises(ValueError):
            self.validate([case])
        case = synthetic()
        case["input"] = {"kind": "raw", "path": "../outside.arw", "sha256": "a" * 64}
        with self.assertRaises(ValueError):
            self.validate([case])

    def test_rejects_invalid_dimensions_noise_and_regions(self):
        for key, value in [("width", 0), ("height", 1000000), ("seed", True),
                           ("shot", -0.01), ("shot", 1e-20), ("read", float("nan"))]:
            case = synthetic()
            case["input"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate([case])
        for rect in [[0, 0, 0, 1], [0.9, 0, 0.2, 1], [0, 0, 1, float("inf")]]:
            case = synthetic()
            case["regions"][0]["rect"] = rect
            with self.subTest(rect=rect), self.assertRaises(ValueError):
                self.validate([case])

    def test_hash_verification_does_not_modify_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "sample.arw"
            path.write_bytes(b"read-only sample")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            result = runner.verify_asset({"path": path.name, "sha256": digest}, root)
            self.assertEqual(result["status"], "VERIFIED")
            self.assertEqual(result["sha256"], digest)
            self.assertEqual(result["bytes"], 16)
            self.assertEqual(path.read_bytes(), b"read-only sample")
            self.assertEqual(runner.verify_asset({"path": path.name, "sha256": "0" * 64}, root)["status"], "HASH_MISMATCH")
            self.assertEqual(runner.verify_asset({"path": "absent.arw", "sha256": digest}, root)["status"], "MISSING")

    def test_malformed_containers_and_huge_numbers_have_validation_errors(self):
        for manifest in [[], None, {"version": True, "cases": [synthetic()]}, {"version": 1, "cases": [None]}]:
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                runner.validate_manifest(manifest)
        case = synthetic()
        case["input"]["shot"] = 10**500
        with self.assertRaises(ValueError):
            self.validate([case])


class ReportTests(unittest.TestCase):
    def fixtures(self):
        request = {"request_id": "a" * 64, "case": synthetic(), "options": runner.PRESETS["off"],
                   "backend": "cpu", "cache_check": False}
        error = {"rgb_rmse": 0.01, "luma_rmse": 0.01, "chroma_rmse": 0.01,
                 "mean_rgb_error": [0, 0, 0], "luma_contrast_gain": None,
                 "luma_laplacian_gain": None, "reference_laplacian_rms": 0}
        variation = {"luma_mean": .18, "luma_stddev": .01, "chroma_stddev": .01}
        result = {"version": 1, "request_id": "a" * 64, "case_id": "flat", "split": "tune",
                  "status": "MEASURED", "options": runner.PRESETS["off"], "backend_requested": "cpu",
                  "bayer_demosaic_requested": "vng",
                  "pipeline": {"demosaic": "not_applicable", "reference_demosaic": "not_applicable"},
                  "source_fingerprint": "fnv1a64-f32le:0123456789abcdef", "output_fingerprint": "fnv1a64-f32le:0123456789abcdef",
                  "width": 256, "height": 256, "decode_ms": 1, "filter_ms": 0, "peak_rss_bytes": None,
                  "reference_kind": "synthetic_truth", "reference_registration": None,
                  "diagnostics": {"outcome": "disabled", "applied": False, "gpu_filter_used": False},
                  "regions": [{"id": "center", "rect_pixels": [64, 64, 128, 128],
                               "source_variation": variation, "output_variation": variation,
                               "source_vs_reference": error, "output_vs_reference": error, "output_vs_source": error}]}
        result["diagnostics"].update({"flat_tiles": 0, "a": None, "b": None, "estimate": {
            "candidate_tiles": 0, "rejected_small": 0, "rejected_structure": 0,
            "rejected_low_noise": 0, "rejected_periodic": 0, "fit_available": False,
            "sample_mean_min": None, "sample_mean_max": None, "relative_fit_rmse": None,
            "sample_variance_median": None, "fit_rmse": None, "relative_fit_median_abs_residual": None,
            "fit_top_decile_error_fraction": None, "constant_variance_fallback": None}})
        return request, result

    def test_complete_matching_report(self):
        request, result = self.fixtures()
        runner.validate_result(result, request)

    def test_laplacian_fields_match_region_size_and_reference_energy(self):
        for rms, gain in ((None, None), (1, None), (0, 1)):
            request, result = self.fixtures()
            result["regions"][0]["source_vs_reference"].update(
                reference_laplacian_rms=rms, luma_laplacian_gain=gain)
            with self.subTest(rms=rms, gain=gain), self.assertRaises(ValueError):
                runner.validate_result(result, request)
        request, result = self.fixtures()
        request["case"]["regions"][0]["rect"] = [0, 0, 2 / 256, 2 / 256]
        result["regions"][0]["rect_pixels"] = [0, 0, 2, 2]
        for key in ("source_vs_reference", "output_vs_reference", "output_vs_source"):
            result["regions"][0][key].update(reference_laplacian_rms=None, luma_laplacian_gain=None)
        runner.validate_result(result, request)
        result["regions"][0]["source_vs_reference"].update(reference_laplacian_rms=.5, luma_laplacian_gain=1)
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)

    def test_registration_report_cannot_substitute_booleans_and_numbers(self):
        for field, value in (("candidate_output_used", 0),
                             ("reference_to_input_gain", True),
                             ("input_to_reference_affine", [[True, 0, -5.25], [0, 1, .75]])):
            request, result = self.fixtures()
            request["case"] = registered_raw()
            request["case"]["reference"]["registration"]["reference_to_input_gain"] = 1
            result["reference_kind"] = "declared_registered_low_noise_reference"
            result["pipeline"] = {"demosaic": "vng", "reference_demosaic": "vng"}
            result["reference_registration"] = json.loads(json.dumps(request["case"]["reference"]["registration"]))
            runner.validate_result(result, request)
            result["reference_registration"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.validate_result(result, request)

    def test_demosaic_choice_must_match_the_request(self):
        request, result = self.fixtures()
        request["bayer_demosaic"] = "dht"
        result["bayer_demosaic_requested"] = "vng"
        with self.assertRaisesRegex(ValueError, "bayer_demosaic"):
            runner.validate_result(result, request)

    def test_demosaic_report_cannot_claim_bayer_processing_for_synthetic_rgb(self):
        request, result = self.fixtures()
        result["pipeline"]["demosaic"] = "vng"
        with self.assertRaisesRegex(ValueError, "demosaic"):
            runner.validate_result(result, request)

    def test_missing_or_fabricated_fit_diagnostics_are_rejected(self):
        request, result = self.fixtures()
        missing = json.loads(json.dumps(result))
        del missing["diagnostics"]["estimate"]
        with self.assertRaises(ValueError):
            runner.validate_result(missing, request)
        for field in ("sample_variance_median", "fit_rmse", "relative_fit_median_abs_residual",
                      "fit_top_decile_error_fraction"):
            invalid = json.loads(json.dumps(result))
            invalid["diagnostics"]["estimate"][field] = [0, 0, 0]
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.validate_result(invalid, request)
        details = result["diagnostics"]
        request["options"] = result["options"] = runner.PRESETS["clean"]
        details.update(outcome="applied", applied=True, flat_tiles=8, a=[0, 0, 0], b=[1, 1, 1])
        estimate = details["estimate"]
        estimate.update(candidate_tiles=8, fit_available=True, sample_mean_min=[.1] * 3,
                        sample_mean_max=[.2] * 3, relative_fit_rmse=[0] * 3,
                        sample_variance_median=[1] * 3, fit_rmse=[0] * 3,
                        relative_fit_median_abs_residual=[0] * 3, fit_top_decile_error_fraction=[0] * 3,
                        constant_variance_fallback=[False] * 3)
        runner.validate_result(result, request)
        for field in ("sample_variance_median", "fit_rmse", "relative_fit_median_abs_residual",
                      "fit_top_decile_error_fraction"):
            for value in (None, [0, 0], [0, -1, 0], [0, float("nan"), 0], [0, True, 0]):
                invalid = json.loads(json.dumps(result))
                invalid["diagnostics"]["estimate"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    runner.validate_result(invalid, request)
        estimate["fit_top_decile_error_fraction"] = [1.01, 0, 0]
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)

    def test_incomplete_or_wrong_identity_report_is_rejected(self):
        request, result = self.fixtures()
        for key, value in [("request_id", "b" * 64), ("case_id", "other"), ("split", "holdout"),
                           ("source_fingerprint", "x"), ("output_fingerprint", None), ("width", 0), ("width", 512),
                           ("options", runner.PRESETS["clean"]), ("backend_requested", "force"),
                           ("regions", [{}]), ("decode_ms", float("nan"))]:
            bad = json.loads(json.dumps(result))
            bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.validate_result(bad, request)
        for bad in [[], {"status": "MEASURED", "output_fingerprint": "x", "regions": [{}]}]:
            with self.assertRaises(ValueError):
                runner.validate_result(bad, request)

    def test_false_backend_and_missing_metrics_are_rejected(self):
        request, result = self.fixtures()
        result["diagnostics"]["gpu_filter_used"] = True
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)
        request, result = self.fixtures()
        del result["regions"][0]["source_vs_reference"]["rgb_rmse"]
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)
        request, result = self.fixtures()
        request["cache_check"] = True
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)

    def test_wrong_region_coordinates_are_rejected(self):
        request, result = self.fixtures()
        result["regions"][0]["rect_pixels"] = [0, 0, 128, 128]
        with self.assertRaises(ValueError):
            runner.validate_result(result, request)


class RunnerFailureTests(unittest.TestCase):
    def run_with_probe(self, operation):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, probe, output = root / "manifest.json", root / "probe", root / "output"
            manifest.write_text(json.dumps({"version": 1, "cases": [synthetic()]}))
            probe.write_bytes(b"test double")
            arguments = [str(RUNNER), "--manifest", str(manifest), "--probe", str(probe),
                         "--assets", str(root), "--output", str(output), "--presets", "off"]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(runner, "git_output", return_value="test"), \
                    mock.patch.object(runner.platform, "platform", return_value="test"), \
                    mock.patch.object(runner.subprocess, "run", side_effect=operation):
                code = runner.main()
            return code, json.loads((output / "results.json").read_text())

    def test_timeout_is_recorded_as_failure(self):
        code, report = self.run_with_probe(subprocess.TimeoutExpired("probe", 1))
        self.assertEqual(code, 1)
        self.assertEqual(report["runs"][0]["status"], "TIMEOUT")
        self.assertEqual(report["quality_verdict"], "NOT_EVALUATED")

    def test_incomplete_success_report_is_not_measured(self):
        def incomplete(command, **_):
            Path(command[2]).write_text(json.dumps({"status": "MEASURED", "output_fingerprint": "x", "regions": [{}]}))
            return subprocess.CompletedProcess(command, 0)
        code, report = self.run_with_probe(incomplete)
        self.assertEqual(code, 1)
        self.assertEqual(report["runs"][0]["status"], "REPORT_ERROR")
        self.assertEqual(report["quality_verdict"], "NOT_EVALUATED")


class NativeRunnerTests(unittest.TestCase):
    def setUp(self):
        if PROBE is None:
            self.skipTest("native probe was not supplied")

    def run_manifest(self, directory, cases, *extra, preset="off"):
        manifest = directory / "manifest.json"
        manifest.write_text(json.dumps({"version": 1, "cases": cases}))
        output = directory / "output"
        command = [sys.executable, str(RUNNER), "--manifest", str(manifest),
                   "--assets", str(directory), "--probe", str(PROBE), "--output", str(output),
                   "--presets", preset, "--backend", "cpu", *extra]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=90)
        report = json.loads((output / "results.json").read_text()) if (output / "results.json").exists() else None
        return completed, report

    def test_synthetic_off_has_truth_and_deterministic_pixels(self):
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [synthetic()], "--repeat", "2")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            rows = report["runs"]
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(row["status"] == "MEASURED" for row in rows))
            first, second = [row["result"] for row in rows]
            self.assertEqual(first["output_fingerprint"], second["output_fingerprint"])
            self.assertEqual(first["source_fingerprint"], first["output_fingerprint"])
            self.assertEqual(first["reference_kind"], "synthetic_truth")
            self.assertEqual(first["diagnostics"]["outcome"], "disabled")
            self.assertIsNone(first["diagnostics"]["a"])
            self.assertIsNone(first["diagnostics"]["b"])
            self.assertEqual(first["pipeline"]["white_balance"], "not_applicable")
            self.assertEqual(first["regions"][0]["output_vs_reference"], first["regions"][0]["source_vs_reference"])
            self.assertEqual(report["quality_verdict"], "NOT_EVALUATED")

    def test_fine_structure_metric_does_not_invent_flat_reference_detail(self):
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [synthetic()])
            self.assertEqual(completed.returncode, 0, completed.stderr)
            region = report["runs"][0]["result"]["regions"][0]
            error = region["output_vs_reference"]
            self.assertIn("luma_laplacian_gain", error)
            self.assertIsNone(error["luma_laplacian_gain"])
            self.assertEqual(error["reference_laplacian_rms"], 0)
            self.assertAlmostEqual(region["output_vs_source"]["luma_laplacian_gain"], 1)

    def test_dht_choice_is_recorded_without_demosaicing_synthetic_rgb(self):
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [synthetic()], "--bayer-demosaic", "dht")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = report["runs"][0]["result"]
            self.assertEqual(result["bayer_demosaic_requested"], "dht")
            self.assertEqual(result["pipeline"]["demosaic"], "not_applicable")
            self.assertEqual(result["source_fingerprint"], result["output_fingerprint"])

    def test_native_probe_rejects_unknown_demosaic_in_direct_requests(self):
        request = {"case": synthetic(), "options": runner.PRESETS["off"], "backend": "cpu",
                   "bayer_demosaic": "unknown", "request_id": "a"*64, "cache_check": False,
                   "crop_prefix": None, "assets": {}}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path, output_path = root / "request.json", root / "result.json"
            input_path.write_text(json.dumps(request))
            completed = subprocess.run([str(PROBE), str(input_path), str(output_path)],
                                       capture_output=True, text=True, timeout=90)
            self.assertNotEqual(completed.returncode, 0)
            result = json.loads(output_path.read_text())
            self.assertIn("invalid Bayer demosaic method", result["message"])

    def test_bayer_choice_reaches_raw_decode_not_just_report_labels(self):
        pixels = (Path(__file__).with_name("fixtures") / "bayer-demosaic.dng").read_bytes()
        fingerprints = {}
        for method in ("vng", "dht"):
            case = synthetic()
            case["input"] = {"kind": "raw", "path": "bayer.dng", "sha256": hashlib.sha256(pixels).hexdigest()}
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "bayer.dng").write_bytes(pixels)
                completed, report = self.run_manifest(root, [case], "--bayer-demosaic", method)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                result = report["runs"][0]["result"]
                self.assertEqual(result["pipeline"]["demosaic"], method)
                self.assertEqual(result["source_fingerprint"], result["output_fingerprint"])
                fingerprints[method] = result["source_fingerprint"]
        self.assertNotEqual(fingerprints["vng"], fingerprints["dht"])

    def test_reference_gain_changes_reference_not_candidate_pixels(self):
        pixels = (Path(__file__).with_name("fixtures") / "bayer-demosaic.dng").read_bytes()
        fingerprints = []
        for gain in (1, 2):
            case = registered_raw()
            case["reference"]["registration"].update(
                input_to_reference_affine=[[1, 0, 0], [0, 1, 0]],
                reference_to_input_gain=gain)
            # TIFF ignores trailing padding, giving identical pixels but distinct asset identities.
            contents = {"input": pixels, "reference": pixels + b"\0"}
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for key, data in contents.items():
                    name = key + ".dng"
                    (root / name).write_bytes(data)
                    case[key].update(path=name, sha256=hashlib.sha256(data).hexdigest())
                completed, report = self.run_manifest(root, [case])
                if report and report["runs"][0].get("result", {}).get("message") == "reference registration requires OpenCV":
                    self.skipTest("reference registration was not compiled")
                self.assertEqual(completed.returncode, 0, completed.stderr)
                result = report["runs"][0]["result"]
                region = result["regions"][0]
                variance = region["source_variation"]
                expected = (gain - 1) * math.hypot(variance["luma_mean"], variance["luma_stddev"])
                self.assertAlmostEqual(region["output_vs_reference"]["luma_rmse"], expected, places=6)
                self.assertEqual(result["source_fingerprint"], result["output_fingerprint"])
                fingerprints.append(result["output_fingerprint"])
        self.assertEqual(*fingerprints)

    def test_reference_registration_outside_image_fails_instead_of_padding_metrics(self):
        pixels = (Path(__file__).with_name("fixtures") / "bayer-demosaic.dng").read_bytes()
        case = registered_raw()
        case["reference"]["registration"]["input_to_reference_affine"] = [[1, 0, 10000], [0, 1, 0]]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for key, data in (("input", pixels), ("reference", pixels + b"\0")):
                name = key + ".dng"
                (root / name).write_bytes(data)
                case[key].update(path=name, sha256=hashlib.sha256(data).hexdigest())
            completed, report = self.run_manifest(root, [case])
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(report["runs"][0]["status"], "PROBE_FAILED")
            self.assertIn("reference", report["runs"][0]["result"]["message"])

    def test_native_registration_rejects_boolean_matrix_and_gain(self):
        fixture = Path(__file__).with_name("fixtures") / "bayer-demosaic.dng"
        for field, value in (("input_to_reference_affine", [[True, 0, 0], [0, 1, 0]]),
                             ("reference_to_input_gain", True)):
            case = registered_raw()
            case["reference"]["registration"][field] = value
            request = {"case": case, "options": runner.PRESETS["off"], "backend": "cpu",
                       "request_id": "a" * 64, "cache_check": False, "crop_prefix": None,
                       "assets": {"input": str(fixture), "reference": str(fixture)}}
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source, target = root / "request.json", root / "report.json"
                source.write_text(json.dumps(request))
                completed = subprocess.run([str(PROBE), str(source), str(target)],
                                           capture_output=True, text=True, timeout=90)
                with self.subTest(field=field):
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertRegex(json.loads(target.read_text())["message"], "boolean|registration")

    def test_reference_affine_direction_and_partial_invalid_border(self):
        fixture_spec = importlib.util.spec_from_file_location("linear_fixture", RUNNER.with_name("make_jxl_fixture.py"))
        fixture = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture)
        def data(shift):
            samples = []
            for y in range(24):
                for x in range(32):
                    sy = min(23, y + shift)
                    value = 5000 + (x * 1237 + sy * 2971 + x * sy * 73) % 30000
                    samples.extend([value] * 3)
            return struct.pack(f"<{len(samples)}H", *samples)
        for offset, full_region in ((1, False), (-1, False), (1, True)):
            with self.subTest(offset=offset, full_region=full_region), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                case = registered_raw()
                for key, shift in (("input", 0), ("reference", 1)):
                    path = root / f"{key}.dng"
                    fixture.write_dng(path, data(shift), 1)
                    case[key].update(path=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                # The fixture's TIFF orientation 6 rotates raw rows into displayed columns.
                case["reference"]["registration"].update(
                    input_to_reference_affine=[[1, 0, offset], [0, 1, 0]], reference_to_input_gain=1)
                if full_region:
                    case["regions"][0]["rect"] = [0, 0, 1, 1]
                completed, report = self.run_manifest(root, [case])
                if report and report["runs"][0].get("result", {}).get("message") == "reference registration requires OpenCV":
                    self.skipTest("reference registration was not compiled")
                if full_region:
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("reference", report["runs"][0]["result"]["message"])
                else:
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    error = report["runs"][0]["result"]["regions"][0]["output_vs_reference"]["rgb_rmse"]
                    if offset == 1:
                        self.assertLess(error, 1e-6)
                    else:
                        self.assertGreater(error, .01)

    def test_native_fitted_diagnostics_survive_runner_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [synthetic()],
                                                   "--cache-check", preset="clean")
            if report and report["runs"][0].get("result", {}).get("wavelet_available") is False:
                self.skipTest("wavelet denoise was not compiled")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = report["runs"][0]["result"]
            self.assertTrue(result["diagnostics"]["applied"])
            estimate = result["diagnostics"]["estimate"]
            self.assertTrue(estimate["fit_available"])
            self.assertEqual(estimate, result["cache"]["diagnostics"]["estimate"])
            for c in range(3):
                self.assertAlmostEqual(estimate["relative_fit_rmse"][c],
                    estimate["fit_rmse"][c] / max(estimate["sample_variance_median"][c], 1e-12))
            self.assertEqual(result["output_fingerprint"], result["cache"]["output_fingerprint"])

    def test_missing_raw_is_not_a_quality_pass(self):
        case = synthetic()
        case["input"] = {"kind": "raw", "path": "missing.arw", "sha256": "0" * 64}
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [case])
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(report["runs"][0]["status"], "MISSING")
            self.assertEqual(report["quality_verdict"], "NOT_EVALUATED")

    def test_negative_signal_with_shot_noise_is_finite_and_unclipped(self):
        case = synthetic()
        case["input"]["pattern"] = "extended"
        case["regions"][0]["rect"] = [0, .25, .25, .5]
        with tempfile.TemporaryDirectory() as temporary:
            completed, report = self.run_manifest(Path(temporary), [case])
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = report["runs"][0]["result"]
            self.assertEqual(result["source_fingerprint"], result["output_fingerprint"])
            self.assertLess(result["regions"][0]["source_variation"]["luma_mean"], -.01)

    def test_decode_failure_retains_native_reason_and_is_not_a_pass(self):
        case = synthetic()
        data = b"not a RAW file"
        case["input"] = {"kind": "raw", "path": "invalid.arw", "sha256": hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "invalid.arw").write_bytes(data)
            completed, report = self.run_manifest(root, [case])
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(report["runs"][0]["status"], "PROBE_FAILED")
            self.assertIn("RAW identification failed", report["runs"][0]["result"]["message"])

    def test_refuses_to_overwrite_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "output").mkdir()
            sentinel = root / "output" / "sentinel"
            sentinel.write_text("keep")
            completed, _ = self.run_manifest(root, [synthetic()])
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=Path)
    options, remaining = parser.parse_known_args()
    PROBE = options.probe.resolve() if options.probe else None
    unittest.main(argv=[sys.argv[0], *remaining])
