#!/usr/bin/env python3
"""Native parity at image borders, tile boundaries and non-primary strengths."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import cv2
import numpy as np

from denoise_p3 import noise_aware_sharpen

PROBE = None
MODES = ["cpu", "metal"]
MATRIX = None


class NativeParityTests(unittest.TestCase):
    def setUp(self):
        if PROBE is None:
            self.skipTest("native P3 probe not supplied")

    def test_frozen_reference_borders_tiles_and_strengths(self):
        random = np.random.default_rng(20261021)
        cases = {"one": np.array([[[-.1, .4, 1.2]]], np.float32),
                 "column": random.uniform(.01, .99, (19, 1, 3)).astype(np.float32),
                 "row": random.uniform(.01, .99, (1, 131, 3)).astype(np.float32),
                 "odd": random.uniform(-.1, 1.1, (65, 67, 3)).astype(np.float32)}
        height, width = 797, 1553
        yy, xx = np.indices((height, width))
        edge = .15 + .7 / (1 + np.exp(np.clip(-(xx - 768 + .1 * (yy - 768)) / 1.5, -60, 60)))
        image = np.repeat(edge[..., None], 3, axis=2).astype(np.float32)
        image += random.normal(0, .001, image.shape).astype(np.float32)
        cases["tiled"] = image
        amounts = [0, .125, .5, 1, 1.375, 2]
        self.check_cases(cases, amounts)

    def test_rendered_roundoff_boundaries(self):
        if MATRIX is None:
            self.skipTest("retained actual-display matrix not supplied")
        cases = {}
        fixtures = [("edge-color-2.0-0.02", "creative-half"),
                    ("sony-a7cii-dsc06251-clipped-highlight", "desaturated"),
                    ("sony-a7cii-dsc06251-clipped-highlight", "creative-full")]
        for index, (case, context) in enumerate(fixtures):
            report = json.loads((MATRIX / case / "source/native/result.json").read_text())
            buffer = next(s for s in report["scenarios"] if s["settings"]["id"] == context)["buffers"]["off"]
            cases[str(index)] = np.fromfile(buffer["path"], "<f4").reshape(buffer["shape"])
        self.check_cases(cases, [0, .5, 1, 2])

    def check_cases(self, cases, amounts):
        with tempfile.TemporaryDirectory(prefix="rawlab-p3-native-") as temp:
            root = Path(temp)
            inputs = []
            for name, source in cases.items():
                path = root / (name + ".f32")
                source.tofile(path)
                inputs.append({"id": name, "path": str(path), "width": source.shape[1], "height": source.shape[0]})
            request = root / "request.json"
            request.write_text(json.dumps({"output": str(root / "output"), "inputs": inputs, "modes": MODES, "amounts": amounts}))
            result = subprocess.run([str(PROBE), str(request)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / "output/result.json").read_text())
            self.assertEqual(len(report["runs"]), len(inputs) * len(MODES) * len(amounts))
            expected = {(name, amount): noise_aware_sharpen(source, amount)[0]
                        for name, source in cases.items() for amount in amounts}
            for run in report["runs"]:
                with self.subTest(case=run["id"], mode=run["mode"], amount=run["amount"]):
                    source = cases[run["id"]]
                    actual = np.fromfile(run["buffer"]["path"], dtype="<f4").reshape(source.shape)
                    reference = expected[run["id"], run["amount"]]
                    self.assertEqual(run["gpu_used"], run["amount"] > 0 and run["mode"] == "metal")
                    if run["amount"] == 0:
                        self.assertEqual(actual.tobytes(), source.tobytes())
                    else:
                        self.assertLessEqual(float(np.max(np.abs(actual - reference))), 2e-6)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--modes", nargs="+", choices=("cpu", "metal"), default=["cpu", "metal"])
    parser.add_argument("--matrix", type=Path)
    args, remaining = parser.parse_known_args()
    PROBE, MODES, MATRIX = args.probe, args.modes, args.matrix
    cv2.setNumThreads(6)
    unittest.main(argv=[__file__, *remaining])
