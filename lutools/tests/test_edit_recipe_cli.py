"""CLI protocol regressions; temporary outputs never modify the RAW fixture."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


class RecipeCLI(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rawlab-recipe-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.recipe = self.root / "edit.json"
        self.document = {
            "schema_version": 1,
            "input": {"path": "missing.ARW"},
            "edits": {"exposure": {"mode": "scene"}},
            "output": {"path": "edited.jpg", "format": "jpeg"},
        }

    def run_cli(self, *arguments, cwd=None):
        return subprocess.run([str(CLI), *map(str, arguments)], cwd=cwd,
                              capture_output=True, text=True, timeout=60)

    def write(self):
        self.recipe.write_text(json.dumps(self.document), encoding="utf-8")

    def test_normalization_without_source_or_output(self):
        self.write()
        result = self.run_cli("--recipe", self.recipe, "--print-recipe")
        self.assertEqual(result.returncode, 0, result.stderr)
        printed = json.loads(result.stdout)
        self.assertEqual(printed["edits"]["exposure"], {"mode": "scene", "ev": 0, "brightness": 1})
        self.assertEqual(printed["edits"]["white_balance"], {"mode": "camera"})
        self.assertEqual(printed["output"]["size"], {"mode": "native"})
        self.assertEqual(printed["input"]["path"], "missing.ARW")
        self.assertFalse((self.root / "edited.jpg").exists())

    def test_rejection_before_processing(self):
        self.document["edits"]["exposure"].pop("mode")
        self.write()
        output = self.root / "edited.jpg"
        output.write_bytes(b"keep existing output")
        result = self.run_cli("--recipe", self.recipe)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("edits.exposure.mode", result.stderr)
        self.assertNotIn("Processing failed", result.stderr)
        self.assertEqual(output.read_bytes(), b"keep existing output")

    def test_no_legacy_overrides(self):
        self.write()
        for flag in ("--no-lut", "--auto-wb", "--exposure"):
            with self.subTest(flag=flag):
                result = self.run_cli("--recipe", self.recipe, flag)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "edited.jpg").exists())

    def test_file_errors_and_limits(self):
        result = self.run_cli("--recipe", self.recipe)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot read recipe", result.stderr)
        self.recipe.write_bytes(b" " * (1024 * 1024 + 1))
        result = self.run_cli("--recipe", self.recipe)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 MiB", result.stderr)

    def test_real_raw_legacy_parity_and_relative_paths(self):
        if RAW is None:
            self.skipTest("real RAW fixture not provided")
        # A temporary copy exercises recipe-relative input without touching the original.
        shutil.copyfile(RAW, self.root / "photo.DNG")
        self.document["input"]["path"] = "photo.DNG"
        for mode in ("scene", "preview", "sensor"):
            with self.subTest(mode=mode):
                self.document["edits"]["exposure"] = {"mode": mode, "ev": 0.5, "brightness": 0.8}
                self.document["edits"]["white_balance"] = {"mode": "auto"}
                self.document["output"]["jpeg_quality"] = 98
                self.write()
                legacy = self.run_cli(RAW, "-o", self.root / "legacy.jpg", "--no-lut",
                                      "--raw-exposure", mode, "--exposure", "0.5",
                                      "--brightness", "0.8", "--auto-wb", "-q", "98")
                self.assertEqual(legacy.returncode, 0, legacy.stderr)
                recipe = self.run_cli("--recipe", self.recipe, cwd=self.root.parent)
                self.assertEqual(recipe.returncode, 0, recipe.stderr)
                self.assertEqual((self.root / "edited.jpg").read_bytes(), (self.root / "legacy.jpg").read_bytes())

        self.document["edits"]["exposure"] = {"mode": "scene"}
        self.document["edits"].pop("white_balance")
        self.document["output"].pop("jpeg_quality")
        self.write()
        legacy = self.run_cli(RAW, "-o", self.root / "legacy.jpg", "--no-lut")
        recipe = self.run_cli("--recipe", self.recipe)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertEqual(recipe.returncode, 0, recipe.stderr)
        self.assertEqual((self.root / "edited.jpg").read_bytes(), (self.root / "legacy.jpg").read_bytes())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=str)
    parser.add_argument("--default-raw", type=str)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    if arguments.raw:
        if not pathlib.Path(arguments.raw).is_file():
            print(f"FAIL edit_recipe_cli: --raw does not exist: {arguments.raw}", file=sys.stderr)
            sys.exit(1)
        RAW = pathlib.Path(arguments.raw).resolve()
    else:
        env_raw = os.environ.get("RAWLAB_TEST_RAW", "")
        if env_raw and not pathlib.Path(env_raw).is_file():
            print(f"FAIL edit_recipe_cli: RAWLAB_TEST_RAW does not exist: {env_raw}", file=sys.stderr)
            sys.exit(1)
        if arguments.default_raw and pathlib.Path(arguments.default_raw).is_file():
            RAW = pathlib.Path(arguments.default_raw).resolve()
        elif env_raw:
            RAW = pathlib.Path(env_raw).resolve()
        else:
            RAW = None
    program = unittest.main(argv=[__file__, *remaining], exit=False)
    if not program.result.wasSuccessful():
        sys.exit(1)
    if RAW is None:
        print("SKIP edit_recipe_cli: default RAW sample not present and RAWLAB_TEST_RAW not set")
        sys.exit(77)
