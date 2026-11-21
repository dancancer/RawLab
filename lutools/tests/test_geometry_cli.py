"""Agent geometry reaches the shared FINAL renderer; fixtures stay read-only."""
import argparse
import copy
import json
import math
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest


class GeometryCLI(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rawlab-geometry-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.recipe = self.root / "edit.json"
        self.document = {
            "schema_version": 2,
            "input": {"path": str(FIXTURES / "linear-uncompressed.dng")},
            "edits": {"exposure": {"mode": "scene"}},
            "output": {"path": "final.png", "format": "png"},
        }

    def run_cli(self, *arguments):
        process = subprocess.run([str(CLI), *map(str, arguments)], cwd=self.root,
                                 capture_output=True, text=True, timeout=120)
        value = json.loads(process.stdout)
        self.assertEqual(value["protocol_version"], 1)
        return process, value

    def render(self, preview=None, edge=16):
        self.recipe.write_text(json.dumps(self.document), encoding="utf-8")
        original = self.recipe.read_bytes()
        arguments = ["--recipe", self.recipe, "--json"]
        if preview:
            arguments.extend(["--preview", preview, "--long-edge", str(edge)])
        process, value = self.run_cli(*arguments)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(value["ok"], value)
        self.assertIsNone(value["error"])
        self.assertEqual(self.recipe.read_bytes(), original)
        output = pathlib.Path(value["result"]["output_path"])
        self.assertEqual(output.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        return output, struct.unpack_from(">II", output.read_bytes(), 16), value

    def test_identity_v1_and_v2_are_identical(self):
        baseline, size, _ = self.render()
        self.assertEqual(size, (24, 32))  # tracked synthetic fixture is oriented by the core
        original = baseline.read_bytes()
        self.document["schema_version"] = 1
        output, _, _ = self.render()
        self.assertEqual(output.read_bytes(), original)
        self.document["schema_version"] = 2
        self.document["edits"]["geometry"] = {}
        output, _, _ = self.render()
        self.assertEqual(output.read_bytes(), original)

    def test_turn_flip_crop_dimensions_and_exact_preview(self):
        self.document["edits"]["geometry"] = {
            "quarter_turns": 1, "flip_horizontal": True, "flip_vertical": True,
            "crop": {"x": .25, "y": .25, "width": .5, "height": .5},
        }
        _, size, _ = self.render()
        self.assertEqual(size, (16, 12))
        preview, size, envelope = self.render("preview.png", edge=8)
        self.assertEqual(size, (8, 6))
        self.assertEqual((envelope["result"]["width"], envelope["result"]["height"]), size)
        preview_bytes = preview.read_bytes()
        self.document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 8}
        final, _, _ = self.render()
        self.assertEqual(final.read_bytes(), preview_bytes)

    def test_straighten_canvas_and_crop_before_resize(self):
        self.document["edits"]["geometry"] = {
            "quarter_turns": 1, "straighten_degrees": 30,
            "crop": {"x": .25, "y": .25, "width": .5, "height": .5},
        }
        # Independent centered rectangle inequality on the 32x24 rotated canvas.
        cosine, sine = math.cos(math.radians(30)), math.sin(math.radians(30))
        scale = min(32 / (32 * cosine + 24 * sine), 24 / (32 * sine + 24 * cosine))
        canvas = (math.floor(32 * scale), math.floor(24 * scale))
        expected = tuple(math.ceil(n * .75) - math.floor(n * .25) for n in canvas)
        _, size, _ = self.render()
        self.assertEqual(size, expected)
        preview, _, _ = self.render("straight.png", edge=6)
        self.document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 6}
        final, _, _ = self.render()
        self.assertEqual(preview.read_bytes(), final.read_bytes())

    def test_invalid_geometry_preserves_existing_output(self):
        final = self.root / "final.png"
        final.write_bytes(b"keep output")
        for version, geometry in ((1, {}), (2, {"quarter_turns": 4}),
                                  (2, {"flip_vertical": 1}),
                                  (2, {"crop": {"x": .75, "width": .5}})):
            with self.subTest(version=version, geometry=geometry):
                self.document["schema_version"] = version
                self.document["edits"]["geometry"] = geometry
                self.recipe.write_text(json.dumps(self.document), encoding="utf-8")
                process, value = self.run_cli("--recipe", self.recipe, "--json")
                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(value["ok"])
                self.assertEqual(value["error"]["code"], "invalid_recipe")
                self.assertIsNone(value["error"]["status"])
                self.assertEqual(final.read_bytes(), b"keep output")

    def test_perspective_v3_canvas_and_exact_preview(self):
        self.document["schema_version"] = 3
        self.document["edits"]["geometry"] = {
            "quarter_turns": 1, "flip_horizontal": True,
            "perspective": {"horizontal": .5, "vertical": -.5},
            "crop": {"x": .25, "y": .25, "width": .5, "height": .5},
        }
        # The two-axis perspective limit keeps 1/(1+.125+.125) of 32x24.
        canvas = (math.floor(32 / 1.25), math.floor(24 / 1.25))
        expected = tuple(math.ceil(n * .75) - math.floor(n * .25) for n in canvas)
        _, size, _ = self.render()
        self.assertEqual(size, expected)
        preview, _, _ = self.render("perspective.png", edge=8)
        self.document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 8}
        final, _, _ = self.render()
        self.assertEqual(preview.read_bytes(), final.read_bytes())

    def test_v3_zero_perspective_preserves_v2_pixels(self):
        self.document["edits"]["geometry"] = {"quarter_turns": 3, "straighten_degrees": -3}
        final, _, _ = self.render()
        original = final.read_bytes()
        self.document["schema_version"] = 3
        self.document["edits"]["geometry"]["perspective"] = {"horizontal": 0, "vertical": 0}
        final, _, _ = self.render()
        self.assertEqual(final.read_bytes(), original)

    def test_real_raw_reusable_geometry_recipe(self):
        if RAW is None:
            self.skipTest("real RAW fixture not provided")
        self.document["input"]["path"] = str(RAW)
        self.document["edits"]["geometry"] = {
            "quarter_turns": 3, "flip_vertical": True, "straighten_degrees": -4,
            "crop": {"x": .125, "y": .25, "width": .75, "height": .5},
        }
        preview, size, _ = self.render("real-preview.png", edge=64)
        self.assertEqual(max(size), 64)
        preview_bytes = preview.read_bytes()
        self.document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 64}
        final, _, _ = self.render()
        self.assertEqual(final.read_bytes(), preview_bytes)
        self.document["output"].pop("size")
        normalized_before = copy.deepcopy(self.document)
        self.recipe.write_text(json.dumps(self.document), encoding="utf-8")
        process, value = self.run_cli("--recipe", self.recipe, "--print-recipe", "--json")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(value["result"]["schema_version"], 2)
        self.assertEqual(value["result"]["output"]["size"], {"mode": "native"})
        self.assertEqual(json.loads(self.recipe.read_text()), normalized_before)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=str)
    parser.add_argument("--default-raw", type=str)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    options, remaining = parser.parse_known_args()
    CLI = options.cli.resolve()
    if options.raw:
        if not pathlib.Path(options.raw).is_file():
            print(f"FAIL geometry_cli: --raw does not exist: {options.raw}", file=sys.stderr)
            sys.exit(1)
        RAW = pathlib.Path(options.raw).resolve()
    else:
        env_raw = os.environ.get("RAWLAB_TEST_RAW", "")
        if env_raw and not pathlib.Path(env_raw).is_file():
            print(f"FAIL geometry_cli: RAWLAB_TEST_RAW does not exist: {env_raw}", file=sys.stderr)
            sys.exit(1)
        if options.default_raw and pathlib.Path(options.default_raw).is_file():
            RAW = pathlib.Path(options.default_raw).resolve()
        elif env_raw:
            RAW = pathlib.Path(env_raw).resolve()
        else:
            RAW = None
    FIXTURES = options.fixtures.resolve()
    program = unittest.main(argv=[__file__, *remaining], exit=False)
    if not program.result.wasSuccessful():
        sys.exit(1)
    if RAW is None:
        print("SKIP geometry_cli: default RAW sample not present and RAWLAB_TEST_RAW not set")
        sys.exit(77)
