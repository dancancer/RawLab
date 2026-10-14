"""Agent CLI contract tests; all outputs live in a temporary directory."""
import argparse
import itertools
import json
import pathlib
import subprocess
import tempfile
import unittest


ERROR_CODES = {
    "invalid_argument", "invalid_recipe", "io_error", "processing_error",
    "unsupported", "out_of_memory", "output_io_error",
}
COMMANDS = {"capabilities", "validate_recipe", "info", "preview", "export"}


class AgentCommands(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rawlab-agent-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.recipe = self.root / "edit.json"
        self.document = {
            "schema_version": 1,
            "input": {"path": "missing.ARW"},
            "edits": {"exposure": {"mode": "scene"}},
            "output": {"path": "edited.jpg", "format": "jpeg"},
        }

    def write_recipe(self):
        self.recipe.write_text(json.dumps(self.document), encoding="utf-8")

    def test_legacy_option_values_do_not_select_agent_mode(self):
        for option in ("-o", "--output"):
            for filename in ("--json", "--capabilities"):
                with self.subTest(option=option, filename=filename):
                    process = self.run_cli(self.root / "missing.ARW", "--no-lut", option, filename, cwd=self.root)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertIn("Processing failed", process.stderr)
                    self.assertNotIn('"protocol_version"', process.stdout)
        for option in ("-l", "--lut"):
            process = self.run_cli(self.root / "missing.ARW", option, "--capabilities", "-o", self.root / "out.jpg")
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("Processing failed", process.stderr)
            self.assertNotIn('"protocol_version"', process.stdout)

    def run_cli(self, *arguments, cwd=None):
        return subprocess.run([str(CLI), *map(str, arguments)], cwd=cwd,
                              capture_output=True, text=True, timeout=120)

    def envelope(self, process, command=None, error=None):
        # json.loads rejects banners, LibRaw progress and a second JSON object.
        try:
            value = json.loads(process.stdout)
        except json.JSONDecodeError as failure:
            self.fail(f"stdout must be one JSON object: {process.stdout!r}; stderr={process.stderr!r}; {failure}")
        self.assertIsInstance(value, dict)
        self.assertEqual(set(value), {"protocol_version", "command", "ok", "result", "error"})
        self.assertEqual(type(value["protocol_version"]), int)
        self.assertEqual(value["protocol_version"], 1)
        self.assertIn(value["command"], COMMANDS)
        if command is not None:
            self.assertEqual(value["command"], command)
        self.assertEqual(type(value["ok"]), bool)
        if error is None:
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(value["ok"])
            self.assertIsNone(value["error"])
            self.assertIsInstance(value["result"], dict)
        else:
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(value["ok"])
            self.assertIsNone(value["result"])
            self.assertIsInstance(value["error"], dict)
            self.assertEqual(set(value["error"]), {"code", "message", "status"})
            self.assertIn(value["error"]["code"], ERROR_CODES)
            self.assertEqual(value["error"]["code"], error)
            self.assertIsInstance(value["error"]["message"], str)
            self.assertTrue(value["error"]["message"])
            if value["error"]["status"] is not None:
                self.assertEqual(type(value["error"]["status"]), int)
                self.assertIn(value["error"]["status"], range(1, 7))
        return value

    def test_capabilities_and_flag_order(self):
        expected = {
            "recipe_versions": [1, 2, 3],
            "commands": ["capabilities", "validate_recipe", "info", "preview", "export"],
            "input_types": ["raw"],
            "output_formats": ["jpeg", "png", "dng"],
            "exposure_modes": ["scene", "preview", "sensor"],
            "geometry_operations": ["crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten", "perspective"],
        }
        for arguments in (("--capabilities", "--json"), ("--json", "--capabilities")):
            with self.subTest(arguments=arguments):
                result = self.envelope(self.run_cli(*arguments), "capabilities")
                for key, value in expected.items():
                    self.assertEqual(result["result"][key], value)
        self.assertFalse((self.root / "edited.jpg").exists())

    def test_validate_recipe_and_flag_order(self):
        self.write_recipe()
        for groups in itertools.permutations((("--recipe", self.recipe), ("--json",), ("--print-recipe",))):
            arguments = [item for group in groups for item in group]
            with self.subTest(arguments=arguments):
                result = self.envelope(self.run_cli(*arguments), "validate_recipe")["result"]
                self.assertEqual(result["schema_version"], 1)
                self.assertEqual(result["input"], {"path": "missing.ARW"})
                self.assertEqual(result["edits"]["exposure"], {"mode": "scene", "ev": 0, "brightness": 1})
                self.assertEqual(result["edits"]["white_balance"], {"mode": "camera"})
                self.assertEqual(result["edits"]["look"], {"path": None, "strength": 1})
                self.assertEqual(result["output"]["jpeg_quality"], 95)
                self.assertEqual(result["output"]["size"], {"mode": "native"})
        self.assertFalse((self.root / "edited.jpg").exists())

    def test_validation_retains_unicode_relative_paths(self):
        self.document["input"]["path"] = "样片/日落 🌅.ARW"
        self.document["output"]["path"] = "导出/调色 📷.png"
        self.document["output"]["format"] = "png"
        self.write_recipe()
        result = self.envelope(self.run_cli("--recipe", self.recipe, "--print-recipe", "--json", cwd=self.root.parent), "validate_recipe")["result"]
        self.assertEqual(result["input"], self.document["input"])
        self.assertEqual(result["output"]["path"], self.document["output"]["path"])

    def test_legacy_normalization_remains_bare_recipe(self):
        self.write_recipe()
        process = self.run_cli("--recipe", self.recipe, "--print-recipe")
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assertEqual(result["schema_version"], 1)
        self.assertNotIn("protocol_version", result)

    def test_unknown_arguments_are_json_errors(self):
        self.write_recipe()
        for arguments in (
            ("--json", "--unknown"),
            ("--unknown", "--json"),
            ("--capabilities", "--unknown", "--json"),
            ("--recipe", self.recipe, "--unknown", "--json"),
            ("--recipe", self.recipe, "--print-recipe", "--json", "--exposure", "1"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), error="invalid_argument")

    def test_missing_and_incompatible_arguments(self):
        self.write_recipe()
        for arguments in (
            ("--json",),
            ("--recipe", "--json"),
            ("--json", "--recipe"),
            ("--print-recipe", "--json"),
            ("--capabilities", "unexpected.ARW", "--json"),
            ("--capabilities", "--recipe", self.recipe, "--json"),
            ("--capabilities", "--print-recipe", "--json"),
            ("--recipe", self.recipe, "--no-lut", "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), error="invalid_argument")
        self.assertFalse((self.root / "edited.jpg").exists())

    def test_missing_recipe_file(self):
        for print_recipe in (False, True):
            arguments = ["--recipe", self.recipe, "--json"]
            if print_recipe:
                arguments.append("--print-recipe")
            with self.subTest(print_recipe=print_recipe):
                self.envelope(self.run_cli(*arguments), "validate_recipe" if print_recipe else "export", "io_error")

    def test_malformed_recipe_is_rejected_before_processing(self):
        target = self.root / "edited.jpg"
        target.write_bytes(b"keep existing output")
        for contents in (b"{", b"[]", json.dumps(self.document).encode() + b"\0junk"):
            self.recipe.write_bytes(contents)
            with self.subTest(contents=contents):
                self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export", "invalid_recipe")
                self.assertEqual(target.read_bytes(), b"keep existing output")
        self.document["edits"]["exposure"].pop("mode")
        self.write_recipe()
        result = self.envelope(self.run_cli("--recipe", self.recipe, "--print-recipe", "--json"), "validate_recipe", "invalid_recipe")
        self.assertIn("edits.exposure.mode", result["error"]["message"])

    def test_missing_input_and_export_flag_order(self):
        self.write_recipe()
        for arguments in (("--recipe", self.recipe, "--json"), ("--json", "--recipe", self.recipe)):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments, cwd=self.root.parent), "export", "io_error")
                self.assertFalse((self.root / "edited.jpg").exists())

    def use_raw_fixture(self):
        if RAW is None or not RAW.is_file():
            self.skipTest("real RAW fixture not provided")
        # A symlink exercises recipe-relative input without copying or modifying RAWs.
        (self.root / "photo.DNG").symlink_to(RAW)
        self.document["input"]["path"] = "photo.DNG"
        self.document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 64}

    def test_real_raw_export_resolves_recipe_relative_output(self):
        self.use_raw_fixture()
        self.document["output"] = {
            "path": "调色-result.png", "format": "png",
            "size": {"mode": "limit_long_edge", "long_edge": 64},
        }
        self.write_recipe()
        process = self.run_cli("--json", "--recipe", self.recipe, cwd=self.root.parent)
        result = self.envelope(process, "export")["result"]
        target = self.root / self.document["output"]["path"]
        self.assertTrue(pathlib.Path(result["output_path"]).is_absolute())
        self.assertEqual(pathlib.Path(result["output_path"]).resolve(), target.resolve())
        self.assertEqual(result["format"], "png")
        self.assertTrue(target.is_file())
        self.assertTrue(target.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_real_raw_png_unwritable_destination(self):
        self.use_raw_fixture()
        target = self.root / "output-is-directory.png"
        target.mkdir()
        self.document["output"]["path"] = target.name
        self.document["output"]["format"] = "png"
        self.write_recipe()
        result = self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export", "processing_error")
        self.assertEqual(result["error"]["status"], 4)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])

    def test_real_raw_dng_unwritable_destination(self):
        self.use_raw_fixture()
        target = self.root / "output-is-directory.dng"
        target.mkdir()
        self.document["output"]["path"] = target.name
        self.document["output"]["format"] = "dng"
        self.write_recipe()
        result = self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export", "output_io_error")
        self.assertEqual(result["error"]["status"], 6)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=pathlib.Path)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    RAW = arguments.raw.resolve() if arguments.raw else None
    unittest.main(argv=[__file__, *remaining])
