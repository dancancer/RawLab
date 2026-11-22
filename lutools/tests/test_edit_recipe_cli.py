"""CLI protocol regressions; temporary outputs never modify the RAW fixture."""
import argparse
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


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

    def test_v17_output_sharpening_normalization(self):
        self.document["schema_version"] = 17
        self.document["processing"] = {"family": "rawlab", "version": 3, "quality": "standard"}
        self.document["edits"].update({
            "white_balance": {"mode": "camera"},
            "look": {"path": None, "strength": 0.0},
            "geometry": {
                "crop": {"x": 0, "y": 0, "width": 1, "height": 1},
                "quarter_turns": 0,
                "flip_horizontal": False,
                "flip_vertical": False,
                "straighten_degrees": 0,
                "perspective": {"horizontal": 0, "vertical": 0},
            },
            "tone": {
                "contrast": 1.0,
                "saturation": 1.0,
                "highlights": 0.0,
                "shadows": 0.0,
                "s_curve": 0.0,
                "curve": {"mode": "legacy", "points": []},
            },
            "detail": {"sharpening": 0.0},
            "hsl": {"hue": [0]*8, "saturation": [0]*8, "lightness": [0]*8},
            "effects": {
                "vignette_amount": 0.0, "vignette_midpoint": 50.0,
                "vignette_roundness": 0.0, "vignette_feather": 50.0,
                "vignette_highlights": 0.0,
                "grain_amount": 0.0, "grain_size": 25.0, "grain_roughness": 50.0,
            },
            "denoise": {
                "raw_level": 0,
                "chroma_mode": 0,
                "wavelet": {"enabled": False, "luma": 0.0, "chroma": 0.0, "coarse": 0.0},
            },
            "lens_correction": {"distortion": False, "tca": False, "auto_crop": False, "profile_id": None},
        })
        self.document["output"]["output_sharpening"] = "standard"
        self.write()
        printed = self.run_cli("--recipe", self.recipe, "--print-recipe")
        self.assertEqual(printed.returncode, 0, printed.stderr)
        doc = json.loads(printed.stdout)
        self.assertEqual(doc["schema_version"], 17)
        self.assertEqual(doc["output"]["output_sharpening"], "standard")

    def test_v17_output_sharpening_and_jpeg_icc_profile(self):
        if RAW is None:
            self.skipTest("real RAW fixture not provided")
        shutil.copyfile(RAW, self.root / "photo.DNG")
        self.document["schema_version"] = 17
        self.document["input"]["path"] = "photo.DNG"
        self.document["processing"] = {"family": "rawlab", "version": 3, "quality": "standard"}
        self.document["edits"].update({
            "white_balance": {"mode": "camera"},
            "look": {"path": None, "strength": 0.0},
            "geometry": {
                "crop": {"x": 0, "y": 0, "width": 1, "height": 1},
                "quarter_turns": 0,
                "flip_horizontal": False,
                "flip_vertical": False,
                "straighten_degrees": 0,
                "perspective": {"horizontal": 0, "vertical": 0},
            },
            "tone": {
                "contrast": 1.0,
                "saturation": 1.0,
                "highlights": 0.0,
                "shadows": 0.0,
                "s_curve": 0.0,
                "curve": {"mode": "legacy", "points": []},
            },
            "detail": {"sharpening": 0.0},
            "hsl": {"hue": [0]*8, "saturation": [0]*8, "lightness": [0]*8},
            "effects": {
                "vignette_amount": 0.0, "vignette_midpoint": 50.0,
                "vignette_roundness": 0.0, "vignette_feather": 50.0,
                "vignette_highlights": 0.0,
                "grain_amount": 0.0, "grain_size": 25.0, "grain_roughness": 50.0,
            },
            "denoise": {
                "raw_level": 0,
                "chroma_mode": 0,
                "wavelet": {"enabled": False, "luma": 0.0, "chroma": 0.0, "coarse": 0.0},
            },
            "lens_correction": {"distortion": False, "tca": False, "auto_crop": False, "profile_id": None},
        })
        self.document["output"].update({
            "path": "out_off.jpg",
            "format": "jpeg",
            "jpeg_quality": 95,
            "size": {"mode": "limit_long_edge", "long_edge": 256},
        })
        self.write()
        off_res = self.run_cli("--recipe", self.recipe)
        self.assertEqual(off_res.returncode, 0, off_res.stderr)
        off_bytes = (self.root / "out_off.jpg").read_bytes()
        self.assertIn(b"ICC_PROFILE\x00\x01\x01", off_bytes)

        self.document["output"]["path"] = "out_high.jpg"
        self.document["output"]["output_sharpening"] = "high"
        self.write()
        high_res = self.run_cli("--recipe", self.recipe)
        self.assertEqual(high_res.returncode, 0, high_res.stderr)
        high_bytes = (self.root / "out_high.jpg").read_bytes()
        self.assertIn(b"ICC_PROFILE\x00\x01\x01", high_bytes)
        self.assertNotEqual(off_bytes, high_bytes)

    def test_v17_raster_relative_wb_cli_renders_shifted_pixels(self):
        def write_png(path: pathlib.Path, width: int = 8, height: int = 8):
            def chunk(kind: bytes, data: bytes) -> bytes:
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
            raw_rows = b"".join(b"\x00" + bytes([150, 140, 130, 255]) * width for _ in range(height))
            ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
            path.write_bytes(
                b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw_rows)) + chunk(b"IEND", b"")
            )

        write_png(self.root / "input.png")
        none_out = self.root / "out_none.png"
        rel_out = self.root / "out_rel.png"
        base_doc = {
            "schema_version": 17,
            "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
            "input": {"path": "input.png", "type": "raster"},
            "edits": {"exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0}, "white_balance": {"mode": "none"}},
            "output": {"path": "out_none.png", "format": "png", "size": {"mode": "native"}},
        }
        self.document = base_doc
        self.write()
        none_res = self.run_cli("--recipe", self.recipe)
        self.assertEqual(none_res.returncode, 0, none_res.stderr)

        rel_doc = json.loads(json.dumps(base_doc))
        rel_doc["edits"]["white_balance"] = {"mode": "relative", "relative_temperature": 5400, "relative_tint": 12}
        rel_doc["output"]["path"] = "out_rel.png"
        self.document = rel_doc
        self.write()
        rel_res = self.run_cli("--recipe", self.recipe)
        self.assertEqual(rel_res.returncode, 0, rel_res.stderr)
        self.assertTrue(none_out.is_file() and rel_out.is_file())
        self.assertNotEqual(none_out.read_bytes(), rel_out.read_bytes())

    def test_v17_combined_raster_relative_wb_curve_v2_grading_v2_sharpening_icc_analyze_and_transfer(self):
        def write_gradient_png(path: pathlib.Path, width: int = 32, height: int = 16):
            def chunk(kind: bytes, data: bytes) -> bytes:
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
            rows = []
            for y in range(height):
                row = bytearray([0])
                for x in range(width):
                    v = int(round(30 + (195 * x) / (width - 1)))
                    g = int(round(28 + (190 * (x + y)) / (width + height - 2)))
                    b = int(round(25 + (185 * y) / (height - 1)))
                    row.extend((v, g, b, 255))
                rows.append(bytes(row))
            ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
            path.write_bytes(
                b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
            )

        write_gradient_png(self.root / "gradient.png")
        std_out = self.root / "combined_standard.jpg"
        std_out_repeat = self.root / "combined_standard_repeat.jpg"
        off_out = self.root / "combined_off.jpg"
        base_doc = {
            "schema_version": 17,
            "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
            "input": {"path": "gradient.png", "type": "raster"},
            "edits": {
                "exposure": {"mode": "sensor", "ev": 0.2, "brightness": 1.0},
                "white_balance": {"mode": "relative", "relative_temperature": 5600, "relative_tint": 14},
                "look": {"path": None, "strength": 0.0},
                "geometry": {
                    "crop": {"x": 0, "y": 0, "width": 1, "height": 1},
                    "quarter_turns": 0,
                    "flip_horizontal": False,
                    "flip_vertical": False,
                    "straighten_degrees": 0,
                    "perspective": {"horizontal": 0, "vertical": 0},
                },
                "tone": {
                    "contrast": 1.1,
                    "saturation": 1.05,
                    "highlights": -0.1,
                    "shadows": 0.15,
                    "black_point": -0.05,
                    "white_point": 0.05,
                    "s_curve": 0.0,
                    "curve": {
                        "mode": "custom",
                        "points": [[0.0, 0.04], [0.5, 0.56], [1.0, 0.96]],
                        "apply_to_luminosity": True,
                        "parametric": {
                            "shadows": 18.0, "darks": -8.0, "lights": 12.0, "highlights": -10.0,
                            "split_shadow": 0.25, "split_midtone": 0.50, "split_highlight": 0.75,
                        },
                        "channels": {
                            "red": {"mode": "custom", "points": [[0.0, 0.0], [0.5, 0.54], [1.0, 1.0]]},
                            "green": {"mode": "legacy", "points": []},
                            "blue": {"mode": "custom", "points": [[0.0, 0.02], [0.5, 0.48], [1.0, 0.98]]},
                        },
                    },
                },
                "color": {"vibrance": 0.15},
                "color_grading": {
                    "shadows": {"hue": 220.0, "saturation": 20.0, "luminance": -10.0},
                    "midtones": {"hue": 40.0, "saturation": 12.0, "luminance": 6.0},
                    "highlights": {"hue": 310.0, "saturation": 15.0, "luminance": -8.0},
                    "global": {"hue": 180.0, "saturation": 10.0, "luminance": 5.0},
                    "blending": 72.0,
                    "balance": -15.0,
                },
                "detail": {"sharpening": 0.25},
                "hsl": {"hue": [0]*8, "saturation": [0]*8, "lightness": [0]*8},
                "effects": {
                    "vignette_amount": 0.0, "vignette_midpoint": 50.0,
                    "vignette_roundness": 0.0, "vignette_feather": 50.0,
                    "vignette_highlights": 0.0,
                    "grain_amount": 0.0, "grain_size": 25.0, "grain_roughness": 50.0,
                },
                "denoise": {
                    "raw_level": 0,
                    "chroma_mode": 0,
                    "wavelet": {"enabled": False, "luma": 0.0, "chroma": 0.0, "coarse": 0.0},
                },
                "lens_correction": {"distortion": False, "tca": False, "auto_crop": False, "profile_id": None},
            },
            "output": {
                "path": "combined_standard.jpg",
                "format": "jpeg",
                "jpeg_quality": 95,
                "output_sharpening": "standard",
                "size": {"mode": "native"},
            },
        }
        self.document = base_doc
        self.write()
        # Run --print-transfer
        pt = self.run_cli("--recipe", self.recipe, "--print-transfer", "--json")
        self.assertEqual(pt.returncode, 0, pt.stderr)
        pt_json = json.loads(pt.stdout)
        self.assertEqual(pt_json["command"], "print_transfer")
        self.assertEqual(pt_json["result"]["values"]["light.curve.apply_to_luminosity"], True)
        self.assertEqual(pt_json["result"]["values"]["color.grading.blending"], 72.0)

        # Run --analyze + --sample (verify diagnostics without mutating export destination)
        res1 = self.run_cli("--recipe", self.recipe, "--analyze", "--sample", "0.5,0.5,center", "--json")
        self.assertEqual(res1.returncode, 0, res1.stderr)
        env1 = json.loads(res1.stdout)
        self.assertTrue(env1["ok"])
        self.assertIn("luma_zones", env1["result"])
        self.assertEqual(env1["result"]["samples"][0]["label"], "center")
        self.assertFalse(std_out.exists())

        # Run full JPEG export and verify APP2 ICC_PROFILE + deterministic 8-bit output
        res_exp = self.run_cli("--recipe", self.recipe, "--json")
        self.assertEqual(res_exp.returncode, 0, res_exp.stderr)
        bytes1 = std_out.read_bytes()
        self.assertIn(b"ICC_PROFILE\x00\x01\x01", bytes1)

        # Verify 8-bit deterministic dithering + output repeatability
        self.document["output"]["path"] = "combined_standard_repeat.jpg"
        self.write()
        res_rep = self.run_cli("--recipe", self.recipe, "--json")
        self.assertEqual(res_rep.returncode, 0, res_rep.stderr)
        self.assertEqual(bytes1, std_out_repeat.read_bytes())

        # Verify output_sharpening: "off" produces distinct bytes
        self.document["output"]["path"] = "combined_off.jpg"
        self.document["output"]["output_sharpening"] = "off"
        self.write()
        res_off = self.run_cli("--recipe", self.recipe, "--json")
        self.assertEqual(res_off.returncode, 0, res_off.stderr)
        self.assertNotEqual(bytes1, off_out.read_bytes())


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
