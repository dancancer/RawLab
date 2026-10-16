"""Exact preview CLI regressions; source fixtures are never modified."""
import argparse
import copy
import json
import pathlib
import struct
import subprocess
import tempfile
import unittest


class AgentPreview(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rawlab-preview-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.recipe_dir = self.root / "recipes"
        self.cwd = self.root / "working"
        self.recipe_dir.mkdir()
        self.cwd.mkdir()
        self.recipe = self.recipe_dir / "edit.json"
        self.document = {
            "schema_version": 1,
            "input": {"path": "photo.dng"},
            "edits": {"exposure": {"mode": "scene", "ev": .25, "brightness": .9}},
            "output": {"path": "final.png", "format": "png", "size": {"mode": "native"}},
        }

    def write_recipe(self):
        self.recipe.write_text(json.dumps(self.document), encoding="utf-8")

    def prepare_synthetic(self):
        if FIXTURES is None or not (FIXTURES / "linear-uncompressed.dng").is_file():
            self.skipTest("synthetic RAW fixture not provided")
        source = self.recipe_dir / "photo.dng"
        source.write_bytes((FIXTURES / "linear-uncompressed.dng").read_bytes())
        source.chmod(0o444)
        self.addCleanup(source.chmod, 0o600)
        self.write_recipe()
        return source

    def run_cli(self, *arguments, cwd=None):
        return subprocess.run([str(CLI), *map(str, arguments)], cwd=cwd or self.cwd,
                              capture_output=True, text=True, encoding="utf-8", timeout=120)

    def envelope(self, process, error=None, command="preview", status=None):
        try:
            value = json.loads(process.stdout)
        except json.JSONDecodeError as failure:
            self.fail(f"stdout must be one JSON object: {process.stdout!r}; stderr={process.stderr!r}; {failure}")
        self.assertIsInstance(value, dict)
        self.assertEqual(set(value), {"protocol_version", "command", "ok", "result", "error"})
        self.assertEqual(type(value["protocol_version"]), int)
        self.assertEqual(value["protocol_version"], 1)
        self.assertEqual(type(value["ok"]), bool)
        if command is not None:
            self.assertEqual(value["command"], command)
        if error is None:
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(value["ok"])
            self.assertIsNone(value["error"])
            self.assertIsInstance(value["result"], dict)
        else:
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(value["ok"])
            self.assertIsNone(value["result"])
            self.assertEqual(set(value["error"]), {"code", "message", "status"})
            self.assertEqual(value["error"]["code"], error)
            self.assertIsInstance(value["error"]["message"], str)
            self.assertTrue(value["error"]["message"])
            if status is not None:
                self.assertEqual(type(value["error"]["status"]), int)
                self.assertEqual(value["error"]["status"], status)
        return value

    def png_size(self, path):
        data = path.read_bytes()
        self.assertGreaterEqual(len(data), 33)
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack_from(">I", data, 8)[0], 13)
        self.assertEqual(data[12:16], b"IHDR")
        width, height, depth, color, compression, filtering, interlace = struct.unpack_from(">IIBBBBB", data, 16)
        self.assertEqual((depth, color, compression, filtering, interlace), (16, 2, 0, 0, 0))
        return width, height

    def assert_preview(self, process, target, edge):
        result = self.envelope(process)["result"]
        self.assertEqual(set(result), {"output_path", "format", "width", "height", "long_edge", "quality"})
        reported = pathlib.Path(result["output_path"])
        self.assertTrue(reported.is_absolute())
        self.assertEqual(reported.resolve(), target.resolve())
        self.assertEqual(result["format"], "png")
        self.assertEqual(result["quality"], "exact")
        for field in ("width", "height", "long_edge"):
            self.assertEqual(type(result[field]), int)
        self.assertEqual(result["long_edge"], edge)
        size = self.png_size(target)
        self.assertEqual((result["width"], result["height"]), size)
        self.assertLessEqual(max(size), edge)
        return size

    def test_capabilities_advertises_preview(self):
        result = self.envelope(self.run_cli("--capabilities", "--json"), command="capabilities")["result"]
        self.assertIn("preview", result["commands"])

    def test_default_edge_and_png_override_use_cwd(self):
        self.prepare_synthetic()
        self.document["output"]["path"] = "final.jpg"
        self.document["output"]["format"] = "jpeg"
        self.write_recipe()
        original = self.recipe.read_bytes()
        target = self.cwd / "预览-result.jpg"
        process = self.run_cli("--recipe", self.recipe, "--preview", target.name, "--json")
        self.assertEqual(self.assert_preview(process, target, 1280), (24, 32))
        self.assertFalse((self.recipe_dir / target.name).exists())
        self.assertFalse((self.recipe_dir / "final.jpg").exists())
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_flag_order(self):
        self.prepare_synthetic()
        target = self.cwd / "preview.png"
        for arguments in (
            ("--json", "--preview", target, "--long-edge", "16", "--recipe", self.recipe),
            ("--long-edge", "16", "--recipe", self.recipe, "--json", "--preview", target),
            ("--preview", target, "--recipe", self.recipe, "--long-edge", "16", "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.assert_preview(self.run_cli(*arguments), target, 16), (12, 16))

    def test_exact_preview_matches_final_and_preserves_original_recipe(self):
        source = self.prepare_synthetic()
        look = self.recipe_dir / "looks" / "swap.cube"
        look.parent.mkdir()
        table = ["#Gamma:sRGB to sRGB", "#Gamut:ITU-R BT.709 to ITU-R BT.709", "LUT_3D_SIZE 2"]
        table.extend(f"{blue} {green} {red}" for blue in range(2) for green in range(2) for red in range(2))
        look.write_text("\n".join(table) + "\n", encoding="utf-8")
        self.document["edits"]["look"] = {"path": "looks/swap.cube", "strength": .5}
        self.write_recipe()
        original_recipe = self.recipe.read_bytes()
        original_source = source.read_bytes()
        preview = self.cwd / "preview.png"
        self.assertEqual(self.assert_preview(self.run_cli("--recipe", self.recipe, "--preview", preview.name,
                         "--long-edge", "16", "--json"), preview, 16), (12, 16))
        matched_document = copy.deepcopy(self.document)
        matched_document["output"] = {
            "path": "matched-final.png", "format": "png",
            "size": {"mode": "limit_long_edge", "long_edge": 16},
        }
        matched_recipe = self.recipe_dir / "matched.json"
        matched_recipe.write_text(json.dumps(matched_document), encoding="utf-8")
        self.envelope(self.run_cli("--recipe", matched_recipe, "--json"), command="export")
        self.assertEqual(preview.read_bytes(), (self.recipe_dir / "matched-final.png").read_bytes())
        self.assertEqual(self.recipe.read_bytes(), original_recipe)
        final = self.envelope(self.run_cli("--recipe", self.recipe, "--json"), command="export")["result"]
        self.assertEqual(final["format"], "png")
        self.assertEqual(self.png_size(self.recipe_dir / "final.png"), (24, 32))
        self.assertEqual(self.recipe.read_bytes(), original_recipe)
        self.assertEqual(source.read_bytes(), original_source)

    def test_uint32_max_edge_never_upscales(self):
        self.prepare_synthetic()
        target = self.cwd / "large-edge.png"
        process = self.run_cli("--recipe", self.recipe, "--preview", target, "--long-edge", "4294967295", "--json")
        self.assertEqual(self.assert_preview(process, target, 4294967295), (24, 32))

    def test_one_pixel_edge(self):
        self.prepare_synthetic()
        target = self.cwd / "one-pixel.png"
        process = self.run_cli("--recipe", self.recipe, "--preview", target, "--long-edge", "1", "--json")
        self.assertEqual(self.assert_preview(process, target, 1), (1, 1))

    def test_preview_without_json(self):
        self.prepare_synthetic()
        target = self.cwd / "human-preview.png"
        process = self.run_cli("--recipe", self.recipe, "--preview", target, "--long-edge", "16")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("Saved:", process.stdout)
        self.assertEqual(self.png_size(target), (12, 16))

    def test_invalid_edge_values(self):
        self.write_recipe()
        for edge in ("0", "-1", "4294967296", "1.5", "16pixels", "", "NaN"):
            with self.subTest(edge=edge):
                self.envelope(self.run_cli("--recipe", self.recipe, "--preview", "preview.png",
                              "--long-edge", edge, "--json"), "invalid_argument")
        self.assertFalse((self.cwd / "preview.png").exists())

    def test_missing_duplicate_and_unknown_operands(self):
        self.write_recipe()
        base = ("--recipe", self.recipe)
        for arguments in (
            (*base, "--preview", "--json"), (*base, "--preview", "", "--json"),
            (*base, "--preview", "preview.png", "--long-edge", "--json"),
            (*base, "--preview", "preview.png", "--long-edge", "16", "--long-edge", "32", "--json"),
            (*base, "--preview", "preview.png", "--preview", "second.png", "--json"),
            (*base, "--preview", "preview.png", "--unknown", "--json"),
            (*base, "--preview", "preview.png", "--json", "--json"),
            ("--preview", "preview.png", "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), "invalid_argument")

    def test_conflicting_commands_and_edge_without_preview(self):
        self.write_recipe()
        for arguments in (
            ("--recipe", self.recipe, "--preview", "preview.png", "--print-recipe", "--json"),
            ("--recipe", self.recipe, "--preview", "preview.png", "--info", "missing.dng", "--json"),
            ("--recipe", self.recipe, "--preview", "preview.png", "--capabilities", "--json"),
            ("--recipe", self.recipe, "--long-edge", "16", "--json"),
            ("--info", "missing.dng", "--long-edge", "16", "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), "invalid_argument", command=None)

    def test_recipe_and_input_errors_preserve_existing_preview(self):
        target = self.cwd / "preview.png"
        target.write_bytes(b"keep existing preview")
        self.envelope(self.run_cli("--recipe", self.recipe, "--preview", target, "--json"), "io_error", status=3)
        self.recipe.write_text("{", encoding="utf-8")
        self.envelope(self.run_cli("--recipe", self.recipe, "--preview", target, "--json"), "invalid_recipe")
        self.write_recipe()
        self.envelope(self.run_cli("--recipe", self.recipe, "--preview", target, "--json"), "io_error", status=3)
        self.assertEqual(target.read_bytes(), b"keep existing preview")

    def test_original_raw_overwrite_is_rejected(self):
        source = self.prepare_synthetic()
        before = source.read_bytes()
        result = self.run_cli("--recipe", self.recipe, "--preview", source, "--json")
        self.envelope(result, "invalid_argument", status=1)
        self.assertEqual(source.read_bytes(), before)
        self.assertFalse((self.recipe_dir / "final.png").exists())

    def test_recipe_overwrite_and_aliases_are_rejected(self):
        self.prepare_synthetic()
        original = self.recipe.read_bytes()
        symlink = self.cwd / "recipe-symlink.png"
        symlink.symlink_to(self.recipe)
        hardlink = self.cwd / "recipe-hardlink.png"
        hardlink.hardlink_to(self.recipe)
        for target in (self.recipe, symlink, hardlink):
            with self.subTest(target=target):
                self.envelope(self.run_cli("--recipe", self.recipe, "--preview", target, "--json"),
                              "invalid_argument", status=1)
                self.assertEqual(self.recipe.read_bytes(), original)

    def test_final_export_cannot_overwrite_recipe(self):
        self.prepare_synthetic()
        self.document["output"]["path"] = "edit.json"
        self.write_recipe()
        original = self.recipe.read_bytes()
        self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "invalid_argument",
                      command="export", status=1)
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_unwritable_preview_destination(self):
        self.prepare_synthetic()
        target = self.cwd / "directory.png"
        target.mkdir()
        self.envelope(self.run_cli("--recipe", self.recipe, "--preview", target, "--json"), "processing_error", status=4)
        self.assertEqual(list(target.iterdir()), [])

    def test_preview_as_legacy_output_filename(self):
        for option in ("-o", "--output"):
            with self.subTest(option=option):
                result = self.run_cli(self.recipe_dir / "missing.ARW", "--no-lut", option, "--preview")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Processing failed", result.stderr)
                self.assertNotIn('"protocol_version"', result.stdout)

    def test_real_raw_preview(self):
        if RAW is None or not RAW.is_file():
            self.skipTest("real RAW fixture not provided")
        (self.recipe_dir / "photo.dng").symlink_to(RAW)
        self.write_recipe()
        target = self.cwd / "real-preview.png"
        result = self.run_cli("--json", "--recipe", self.recipe, "--preview", target, "--long-edge", "64")
        self.assert_preview(result, target, 64)
        self.assertFalse((self.recipe_dir / "final.png").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=pathlib.Path)
    parser.add_argument("--fixtures", type=pathlib.Path)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    RAW = arguments.raw.resolve() if arguments.raw else None
    FIXTURES = arguments.fixtures.resolve() if arguments.fixtures else None
    unittest.main(argv=[__file__, *remaining])
