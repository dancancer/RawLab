import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from lutools.lutprep.native import compile_dcp
from lutools.lutprep.reference import compare_reports, evaluate_samples, load_samples
from lutools.tests.test_lutprep_dcp import write_dcp


class LookReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.look = self.root / "look.rlook"
        compile_dcp(write_dcp(self.root / "look.dcp"), self.look)
        self.samples = {"schema_version": 1, "input_space": "scene-linear-srgb-d65", "samples": [
            {"id": "gray", "category": "gray", "rgb": [.18, .18, .18]},
            {"id": "highlight", "category": "highlight", "rgb": [2, 1, -.1]},
        ]}

    def probe(self, command, **kwargs):
        self.assertEqual(command[1], "--evaluate")
        self.assertEqual(Path(command[2]), self.look.resolve())
        raw = np.fromfile(command[3], dtype="<f4")
        self.assertEqual(raw.size, 6)
        np.asarray([.4, .4, .4, 1, .8, 0], dtype="<f4").tofile(command[4])
        return subprocess.CompletedProcess(command, 0, "", "")

    def report(self):
        with patch("lutools.lutprep.reference.subprocess.run", side_effect=self.probe):
            return evaluate_samples(self.look, Path("native-probe"), self.samples)

    def reference(self, actual):
        reference = copy.deepcopy(actual)
        reference["evaluator"] = {"name": "Synthetic unit-test oracle", "version": "1",
                                  "kind": "independent", "provenance": "literal fixture, not camera evidence"}
        return reference

    def test_fixed_samples_cover_named_boundaries(self):
        samples = load_samples()
        self.assertGreaterEqual(len(samples["samples"]), 16)
        self.assertEqual({s["category"] for s in samples["samples"]},
                         {"gray", "skin-like", "sky", "foliage", "saturated", "negative", "highlight"})
        self.assertTrue(any(min(s["rgb"]) < 0 for s in samples["samples"]))
        self.assertTrue(any(max(s["rgb"]) > 1 for s in samples["samples"]))

    def test_evaluate_uses_float32_and_keeps_appearance_unverified(self):
        before = self.look.read_bytes()
        actual = self.report()
        self.assertEqual(actual["evaluator"]["kind"], "internal")
        self.assertEqual(actual["appearance"]["status"], "unverified")
        self.assertEqual(actual["reference_status"], "not_supplied")
        self.assertEqual(actual["samples"][0]["input_rgb"], np.asarray([.18] * 3, dtype="<f4").tolist())
        self.assertEqual(len(actual["preset"]["sha256"]), 64)
        self.assertEqual(self.look.read_bytes(), before)
        json.dumps(actual, allow_nan=False)

    def test_probe_errors_and_invalid_outputs_fail(self):
        for result in ["failure", "missing", "truncated", "nan", "out-of-range"]:
            def run(command, **kwargs):
                values = {"truncated": [0], "nan": [float("nan")] * 6,
                          "out-of-range": [2] * 6}
                if result in values:
                    np.asarray(values[result], dtype="<f4").tofile(command[4])
                return subprocess.CompletedProcess(command, 4 if result == "failure" else 0, "", "probe failed")
            with self.subTest(result=result), patch("lutools.lutprep.reference.subprocess.run", side_effect=run):
                with self.assertRaises(ValueError):
                    evaluate_samples(self.look, Path("probe"), self.samples)

    def test_invalid_or_duplicate_samples_fail_before_probe(self):
        for key, value in [("id", "gray"), ("rgb", [1, 2]), ("rgb", [float("nan"), 0, 0]),
                           ("rgb", [1e100, 0, 0])]:
            invalid = copy.deepcopy(self.samples)
            invalid["samples"][1][key] = value
            with self.subTest(key=key, value=value), patch("lutools.lutprep.reference.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    evaluate_samples(self.look, Path("probe"), invalid)
                run.assert_not_called()

    def test_comparison_reports_threshold_and_category_errors_not_camera_equivalence(self):
        actual = self.report()
        reference = self.reference(actual)
        reference["samples"][0]["output_rgb"][0] += .01
        result = compare_reports(actual, reference, .02)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["scope"], "named-sample-agreement-only")
        self.assertEqual(result["sample_count"], 2)
        self.assertAlmostEqual(result["errors"]["max"], .01)
        self.assertAlmostEqual(result["categories"]["gray"]["max"], .01)
        self.assertEqual(compare_reports(actual, reference, .001)["status"], "failed")

    def test_internal_or_undeclared_reference_is_rejected(self):
        actual = self.report()
        for evaluator in [actual["evaluator"], {}, {"name": "RawLab CPU", "version": "1",
                                                  "kind": "independent", "provenance": "same evaluator"}]:
            reference = self.reference(actual)
            reference["evaluator"] = evaluator
            with self.subTest(evaluator=evaluator), self.assertRaises(ValueError):
                compare_reports(actual, reference, .01)

    def test_mismatched_conditions_are_rejected(self):
        actual = self.report()
        mutations = [lambda r: r.update(output_space="linear-srgb"),
                     lambda r: r["preset"].update(sha256="other"),
                     lambda r: r["samples"].reverse(),
                     lambda r: r["samples"][0].update(input_rgb=[0, 0, 0]),
                     lambda r: r["samples"][0].update(output_rgb=[float("nan"), 0, 0]),
                     lambda r: r["samples"][0].update(output_rgb=[2, 0, 0])]
        for mutate in mutations:
            reference = self.reference(actual)
            mutate(reference)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                compare_reports(actual, reference, .01)
        for threshold in [-1, float("nan"), float("inf")]:
            with self.assertRaises(ValueError):
                compare_reports(actual, self.reference(actual), threshold)

    def test_actual_requires_declared_native_evaluator(self):
        actual = self.report()
        reference = self.reference(actual)
        for evaluator in [None, {}, reference["evaluator"]]:
            actual["evaluator"] = evaluator
            with self.subTest(evaluator=evaluator), self.assertRaises(ValueError):
                compare_reports(actual, reference, .01)

    def test_cli_rejects_malformed_report_shapes_without_traceback(self):
        actual = self.report()
        actual_path, reference_path = self.root / "actual.json", self.root / "reference.json"
        actual_path.write_text(json.dumps(actual))
        for invalid in [[], {"evaluator": None}, {**self.reference(actual), "preset": None}]:
            reference_path.write_text(json.dumps(invalid))
            result = subprocess.run([sys.executable, "-m", "lutools.lutprep.reference", "compare",
                                     str(actual_path), str(reference_path), "--max-error", ".01"],
                                    capture_output=True, text=True)
            with self.subTest(invalid=invalid):
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    @unittest.skipUnless(os.environ.get("RAWLAB_DCP_PROBE"), "native probe not supplied")
    def test_real_native_probe_evaluates_all_frozen_samples(self):
        report = evaluate_samples(self.look, Path(os.environ["RAWLAB_DCP_PROBE"]))
        self.assertEqual(len(report["samples"]), len(load_samples()["samples"]))
        self.assertEqual(report["appearance"]["status"], "unverified")
