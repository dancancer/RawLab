"""Agent CLI contract tests; all outputs live in a temporary directory."""
import argparse
import errno
import itertools
import json
import os
import pathlib
import platform
import struct
import subprocess
import tempfile
import unittest
import sys
import zlib


ERROR_CODES = {
    "invalid_argument", "invalid_recipe", "io_error", "processing_error",
    "unsupported", "out_of_memory", "output_io_error",
}
COMMANDS = {
    "capabilities", "validate_recipe", "info", "preview", "export",
    "analyze", "print_transfer", "save_preset", "sync_photo_edit",
}


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
                              capture_output=True, text=True, encoding="utf-8", timeout=120)

    def test_raw_failure_without_lut_does_not_blame_the_look(self):
        broken = self.root / "broken.NEF"
        broken.write_bytes(b"not a raw file")
        process = self.run_cli(broken, "--no-lut", "-o", self.root / "out.jpg")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Processing failed", process.stderr)
        self.assertNotIn("Use a declared Fuji", process.stderr)
        self.assertFalse((self.root / "out.jpg").exists())

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
            self.assertIn(value["error"]["code"], {error} if isinstance(error, str) else error)
            self.assertIsInstance(value["error"]["message"], str)
            self.assertTrue(value["error"]["message"])
            if value["error"]["status"] is not None:
                self.assertEqual(type(value["error"]["status"]), int)
                self.assertIn(value["error"]["status"], range(1, 7))
        return value

    def test_capabilities_and_flag_order(self):
        hdr=sys.platform!="darwin" or tuple(map(int,platform.mac_ver()[0].split(".")[:2]))>=(15,0)
        declared = self.envelope(self.run_cli("--capabilities", "--json"), "capabilities")["result"]
        proraw = "proraw" in declared["input_types"]
        expected = {
            "recipe_versions": [1, 2, 3, 4, 5] + ([6] if hdr else []) + [7] + ([8, 9, 10, 11, 12, 13, 14, 15, 16] if hdr else []) + [17, 18] + ([19] if hdr else []) + [20],
            "commands": [
                "capabilities", "validate_recipe", "info", "preview", "export",
                "analyze", "print_transfer", "save_preset", "sync_photo_edit",
            ],
            "input_types": (["raw", "raster"] if sys.platform in ("darwin", "win32") else ["raw"])+(["hdr_raster"] if hdr else [])+(["proraw"] if proraw else []),
            "output_formats": ["jpeg", "png", "dng"]+(["hdr_jpeg"] if hdr else []),
            "exposure_modes": ["scene", "preview", "sensor"],
            "geometry_operations": ["crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten", "perspective"],
        }
        for arguments in (("--capabilities", "--json"), ("--json", "--capabilities")):
            with self.subTest(arguments=arguments):
                result = self.envelope(self.run_cli(*arguments), "capabilities")
                for key, value in expected.items():
                    self.assertEqual(result["result"][key], value)
                if hdr:
                    capabilities = result["result"]["hdr"]
                    self.assertEqual(capabilities["source_recipe_version"], 14)
                    self.assertEqual(capabilities["channel_curve_recipe_version"], 15)
                    self.assertEqual(capabilities["input_types"], ["hdr_raster", "raw"]+(["proraw"] if proraw else []))
                    self.assertEqual(capabilities["output_formats"], ["hdr_jpeg", "jpeg", "png", "dng"])
                    self.assertEqual(capabilities["processing_version"], 1)
                    self.assertEqual(capabilities["processing_versions"], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
                    self.assertEqual(capabilities["tone_recipe_version"], 8)
                    self.assertEqual(capabilities["tone_adjustments"], ["black_point", "white_point", "s_curve", "curve"])
                    self.assertEqual(capabilities["color_recipe_version"], 9)
                    self.assertEqual(capabilities["color_adjustments"], ["vibrance", "hsl", "color_grading"])
                    self.assertEqual(capabilities["rendition_recipe_version"], 10)
                    self.assertEqual(capabilities["effects_recipe_version"], 11)
                    self.assertEqual(capabilities["effects_adjustments"], ["vignette", "grain"])
                    self.assertEqual(capabilities["detail_recipe_version"], 12)
                    self.assertEqual(capabilities["detail_adjustments"], ["sharpening", "clarity", "dehaze", "denoise"])
                    self.assertEqual(capabilities["look_recipe_version"], 13)
                    self.assertEqual(capabilities["look_profile"], "display-linear-srgb-v1")
                x3f = result["result"]["x3f"]
                self.assertIs(type(x3f["normal_available"]), bool)
                self.assertEqual(x3f["recipe_min_version"], 7)
                self.assertEqual(x3f["modes"], ["legacy", "normal-v1"])
                features = result["result"]["optional_features"]
                self.assertEqual(result["result"]["tone_controls"], {
                    "version": 1, "recipe_min_version": 5, "range": [-1, 1],
                    "fields": ["tone.black_point", "tone.white_point", "color.vibrance"],
                })
                self.assertEqual(result["result"]["color_grading"], {
                    "version": 2, "recipe_min_version": 5, "v2_recipe_min_version": 17,
                    "zones": ["shadows", "midtones", "highlights", "global"],
                    "hue_degrees": {"minimum": 0, "exclusive_maximum": 360}, "saturation_range": [0, 100],
                    "luminance_range": [-100, 100], "blending_range": [0, 100], "balance_range": [-100, 100],
                })
                self.assertEqual(result["result"]["tone_curve"], {
                    "version": 2, "recipe_min_version": 5, "v2_recipe_min_version": 17,
                    "modes": ["legacy", "custom"],
                    "channels": ["red", "green", "blue"], "max_points": 33, "interpolation": "pchip",
                    "fixed_endpoints": False, "monotone": True, "apply_to_luminosity": True,
                    "parametric": ["highlights", "lights", "darks", "shadows", "split_shadow", "split_midtone", "split_highlight"],
                })
                self.assertEqual(result["result"]["output_sharpening"], ["off", "low", "standard", "high"])
                self.assertEqual(result["result"]["atmosphere"], {
                    "version": 1, "recipe_min_version": 5, "range": [-1, 1],
                    "fields": ["effects.clarity", "effects.dehaze"], "backend": "cpu",
                    "gpu_force": "unsupported", "preview": "complete_source",
                })
                if sys.platform in ("darwin", "win32"):
                    self.assertEqual(result["result"]["raster_input"]["max_pixels"], 128_000_000)
                    self.assertEqual(result["result"]["raster_input"]["bits_per_component"], [8, 16])
                    self.assertEqual(result["result"]["raster_input"]["tiff_bits_per_component"], [8, 16])
                    self.assertEqual(result["result"]["raster_input"]["white_balance_modes"], ["none", "relative"])
                if sys.platform == "win32":
                    self.assertEqual(result["result"]["raster_input"]["formats"], ["jpeg", "png", "tiff", "heif"])
                self.assertEqual(set(features), {"wavelet_denoise", "chroma_denoise", "lens_correction"})
                self.assertTrue(all(isinstance(value, bool) for value in features.values()))
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

    def test_info_known_raw_extensions_ignore_rgb_thumbnail(self):
        source = pathlib.Path(__file__).parent / "fixtures/linear-uncompressed.dng"
        payload = bytearray(source.read_bytes())
        raw_ifd = struct.unpack_from("<I", payload, 4)[0]
        pixels = len(payload)
        payload.extend(b"\x80" * (4 * 3 * 3))
        bits = len(payload)
        payload.extend(struct.pack("<3H", 8, 8, 8))
        thumbnail_ifd = len(payload)
        # IFD0 模拟 4x3 RGB 缩略图，原有 32x24 RAW 目录及像素仍通过 SubIFDs 可达。
        tags = {
            256: (4, 1, 4), 257: (4, 1, 3), 258: (3, 3, bits),
            259: (3, 1, 1), 262: (3, 1, 2), 273: (4, 1, pixels),
            277: (3, 1, 3), 278: (4, 1, 3), 279: (4, 1, 36),
            284: (3, 1, 1), 330: (4, 1, raw_ifd),
        }
        payload.extend(struct.pack("<H", len(tags)))
        for tag, (kind, count, value) in sorted(tags.items()):
            payload.extend(struct.pack("<HHII", tag, kind, count, value))
        payload.extend(b"\0" * 4)
        struct.pack_into("<I", payload, 4, thumbnail_ifd)
        if sys.platform in ("darwin", "win32"):
            alias = self.root / "thumbnail.unknown"
            alias.write_bytes(payload)
            result = self.envelope(self.run_cli("--info", alias, "--json"), "info")["result"]
            self.assertEqual(result["input_type"], "raster")
            self.assertEqual(result["identified_size"], {"width": 4, "height": 3, "orientation": 1})
        for extension in ("arw", "arq", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf",
                          "rw2", "rwl", "orf", "pef", "srw", "raw", "3fr", "fff", "iiq", "mos",
                          "srf", "sr2", "mrw", "kdc", "dcr", "erf", "x3f", "NeF"):
            with self.subTest(extension=extension):
                alias = self.root / f"thumbnail.{extension}"
                alias.write_bytes(payload)
                result = self.envelope(self.run_cli("--info", alias, "--json"), "info")["result"]
                self.assertEqual(result["camera"], {"make": "RawLab", "model": "Synthetic"})
                self.assertEqual(result["identified_size"], {"width": 32, "height": 24, "orientation": 6})

    def test_info_known_raw_extension_does_not_probe_hdr(self):
        alias = self.root / "broken.NEF"
        alias.write_bytes(b"\xff\xd8http://ns.adobe.com/hdr-gain-map/1.0/\0invalid" + b"\0" * 4096)
        result = self.envelope(self.run_cli("--info", alias, "--json"), "info", "unsupported")
        self.assertNotIn("HDR", result["error"]["message"])

    def test_info_unknown_extension_rejects_damaged_hdr(self):
        alias = self.root / "broken.jpe"
        alias.write_bytes(b"\xff\xd8http://ns.adobe.com/hdr-gain-map/1.0/\0invalid" + b"\0" * 4096)
        result = self.envelope(self.run_cli("--info", alias, "--json"), "info", {"unsupported", "processing_error"})
        self.assertIn("HDR", result["error"]["message"])

    @unittest.skipUnless(sys.platform in ("darwin", "win32"), "display image loader requires Mac or Windows")
    def test_info_recognizes_png_content_without_known_extension(self):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        alias = self.root / "source.unknown"
        alias.write_bytes(b"\x89PNG\r\n\x1a\n" +
                          chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 3, 8, 2, 0, 0, 0)) +
                          chunk(b"IDAT", zlib.compress((b"\0" + b"\x80" * 12) * 3)) + chunk(b"IEND", b""))
        result = self.envelope(self.run_cli("--info", alias, "--json"), "info")["result"]
        self.assertEqual(result["input_type"], "raster")
        self.assertEqual(result["identified_size"], {"width": 4, "height": 3, "orientation": 1})

    @unittest.skipUnless(sys.platform in ("darwin", "win32"), "display image loader requires Mac or Windows")
    def test_info_recognizes_jpeg_content_without_known_extension(self):
        self.document["input"]["path"] = str(pathlib.Path(__file__).parent / "fixtures/linear-uncompressed.dng")
        self.document["output"]["path"] = str(self.root / "source.jpg")
        self.write_recipe()
        self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export")
        data = (self.root / "source.jpg").read_bytes()
        for name in ("source.jfif", "source.jpe", "source"):
            with self.subTest(name=name):
                alias = self.root / name
                alias.write_bytes(data)
                result = self.envelope(self.run_cli("--info", alias, "--json"), "info")["result"]
                self.assertEqual(result["input_type"], "raster")
                self.assertGreater(result["identified_size"]["width"], 0)

    def test_info_recognizes_gain_map_content_without_known_extension(self):
        capabilities = self.envelope(self.run_cli("--capabilities", "--json"), "capabilities")["result"]
        if 14 not in capabilities["recipe_versions"]:
            self.skipTest("CLI runtime has no HDR v14 capability")
        self.document = {
            "schema_version": 14,
            "processing": {"family": "rawlab_hdr", "version": 7, "quality": "standard"},
            "input": {"path": str(pathlib.Path(__file__).parent / "fixtures/bayer-demosaic.dng"), "type": "raw"},
            "edits": {"exposure": {"ev": .5}, "white_balance": {"mode": "relative"}},
            "output": {"path": "hdr.jpg", "format": "hdr_jpeg", "base_color": "srgb"},
        }
        self.write_recipe()
        self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export")
        data = (self.root / "hdr.jpg").read_bytes()
        for name in ("hdr.jfif", "hdr.jpe", "hdr"):
            with self.subTest(name=name):
                alias = self.root / name
                alias.write_bytes(data)
                result = self.envelope(self.run_cli("--info", alias, "--json"), "info")["result"]
                self.assertEqual(result["input_type"], "hdr_raster")

    def test_hdr_print_transfer_is_accepted_by_save_preset_for_every_processing_version(self):
        # The CLI builds HDR transfers from the store's own per-version field table, so what it
        # prints for any hdr_processing_version must be a preset the store accepts unchanged.
        capabilities = self.envelope(self.run_cli("--capabilities", "--json"), "capabilities")["result"]
        if 19 not in capabilities["recipe_versions"]:
            self.skipTest("CLI runtime has no HDR v19 capability")
        schemas = {1: 6, 2: 8, 3: 9, 4: 10, 5: 11, 6: 12, 7: 14, 8: 15, 9: 16, 10: 19}
        # Sample fields keyed by the processing version that introduces them (v8 and v10 add no
        # transfer field). A field missing from the core table would drop silently from the
        # printed transfer, so presence at and absence below each version are checked as well as
        # store acceptance.
        introduced = {
            1: {"light.exposure", "hdr.relative_tint", "geometry.quarter_turns"},
            2: {"tone.black_point", "light.curve"},
            3: {"color.vibrance", "color.grading.shadows", "color.hsl.hue.red"},
            4: {"hdr.peak_limit_ev", "hdr.sdr_contrast"},
            5: {"effects.vignette.amount", "effects.grain.amount"},
            6: {"detail.sharpening", "effects.clarity"},
            7: {"hdr.look"},
            9: {"color.grading.global", "light.curve.parametric", "light.curve.apply_to_luminosity"},
        }
        for hdr_version, schema in schemas.items():
            edits = {
                "exposure": {"ev": 0.5}, "white_balance": {"mode": "relative", "relative_tint": 6},
                "tone": {"contrast": 0.3, "saturation": 0.2, "highlights": -0.2, "shadows": 0.2},
                "geometry": {"quarter_turns": 1, "straighten_degrees": 2.0},
            }
            if schema >= 8:
                edits["tone"].update({"black_point": -0.2, "white_point": 0.4,
                                      "curve": {"mode": "custom", "points": [[0, 0], [0.5, 0.6], [1, 1]]}})
            if schema >= 9:
                edits["color"] = {"vibrance": 0.3}
                edits["color_grading"] = {"shadows": {"hue": 210, "saturation": 12}}
            if schema >= 10:
                edits["rendition"] = {"peak_limit_ev": 2, "sdr_contrast": 0.2}
            if schema >= 11:
                edits["effects"] = {"vignette_amount": -40, "grain_amount": 30}
            if schema >= 12:
                edits["detail"] = {"sharpening": 1.0, "clarity": 0.4}
            if schema >= 14:
                edits["look"] = {"path": "look.cube", "sha256": "ab" * 32, "strength": 0.8}
            if schema >= 16:
                edits["color_grading"]["shadows"]["luminance"] = -10
                edits["color_grading"]["global"] = {"hue": 300, "saturation": 9, "luminance": -4}
            for input_type in (("hdr_raster", "raw") if schema >= 14 else ("hdr_raster",)):
                with self.subTest(hdr_processing_version=hdr_version, input_type=input_type):
                    self.document = {
                        "schema_version": schema,
                        "processing": {"family": "rawlab_hdr", "version": hdr_version, "quality": "standard"},
                        "input": {"path": "source", "type": input_type},
                        "edits": edits,
                        "output": {"path": "hdr.jpg", "format": "hdr_jpeg", "base_color": "srgb"},
                    }
                    self.write_recipe()
                    transfer = self.envelope(self.run_cli("--recipe", self.recipe, "--print-transfer", "--json"),
                                             "print_transfer")["result"]
                    self.assertEqual(transfer["source"]["hdr_processing_version"], hdr_version)
                    keys = set(transfer["values"])
                    for version, fields in introduced.items():
                        if version <= hdr_version:
                            self.assertLessEqual(fields, keys, f"v{version} fields missing at v{hdr_version}")
                        else:
                            self.assertFalse(fields & keys, f"v{version} fields present at v{hdr_version}")
                    # Camera development is an input-type rule the CLI keeps: RAW sources only.
                    self.assertEqual("hdr.camera_development" in transfer["values"], input_type == "raw")
                    request = self.root / f"preset-{hdr_version}-{input_type}.json"
                    request.write_text(json.dumps({
                        "data_dir": str(self.root / f"store-{hdr_version}-{input_type}"),
                        "name": f"HDR v{hdr_version} {input_type}",
                        "is_raw": transfer["source"]["is_raw"],
                        "processing_version": transfer["source"]["processing_version"],
                        "hdr_processing_version": hdr_version,
                        "values": transfer["values"],
                    }), encoding="utf-8")
                    saved = self.envelope(self.run_cli("--save-preset", "--request", request, "--json"), "save_preset")
                    self.assertEqual(saved["result"]["action"], "created")

    def test_hdr_oversized_long_edge_is_an_argument_error(self):
        capabilities = self.envelope(self.run_cli("--capabilities", "--json"), "capabilities")["result"]
        if 14 not in capabilities["recipe_versions"]:
            self.skipTest("CLI runtime has no HDR v14 capability")
        self.document = {
            "schema_version": 14,
            "processing": {"family": "rawlab_hdr", "version": 7, "quality": "standard"},
            "input": {"path": str(pathlib.Path(__file__).parent / "fixtures/bayer-demosaic.dng"), "type": "raw"},
            "edits": {"exposure": {"ev": 0}, "white_balance": {"mode": "relative"}},
            "output": {"path": "hdr.jpg", "format": "hdr_jpeg", "base_color": "srgb"},
        }
        self.write_recipe()
        # 外部调用方（MCP）按错误码区分参数错误与处理失败；超出 1..65535 的长边必须是参数错误。
        for mode in (("--preview", self.root / "preview.png"), ("--analyze",)):
            with self.subTest(mode=mode[0]):
                error = self.envelope(self.run_cli("--recipe", self.recipe, *mode, "--long-edge", "70000", "--json"),
                                      error="invalid_argument")["error"]
                self.assertEqual(error["status"], 1)
                self.assertFalse((self.root / "preview.png").exists())

    def test_lens_database_validation_flag_order(self):
        self.write_recipe()
        for groups in itertools.permutations((("--recipe", self.recipe), ("--lens-database", self.root / "lenses.xml"), ("--print-recipe",))):
            arguments = [item for group in groups for item in group]
            with self.subTest(arguments=arguments):
                process = self.run_cli(*arguments)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(json.loads(process.stdout)["schema_version"], 1)

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

    def create_link(self, alias, source, kind):
        try:
            if kind == "symlink": alias.symlink_to(source)
            else: alias.hardlink_to(source)
        except NotImplementedError as failure:
            self.skipTest(f"{kind} unsupported: {failure}")
        except OSError as failure:
            unavailable = {errno.EACCES, errno.EPERM, errno.ENOSYS,
                           getattr(errno, "ENOTSUP", -1), getattr(errno, "EOPNOTSUPP", -1)}
            if failure.errno in unavailable or getattr(failure, "winerror", None) in {1, 5, 50, 1314}:
                self.skipTest(f"{kind} unavailable: {failure}")
            raise

    def use_raw_fixture(self):
        if RAW is None:
            self.skipTest("real RAW fixture not provided")
        # A symlink exercises recipe-relative input without copying or modifying RAWs.
        self.create_link(self.root / "photo.DNG", RAW, "symlink")
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
        result = self.envelope(self.run_cli("--recipe", self.recipe, "--json"), "export", "output_io_error")
        self.assertEqual(result["error"]["status"], 6)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])

    def test_sources_are_protected_through_output_aliases(self):
        # The look guard originates in core-owner commit 4f95bceb.
        sources = {"recipe": self.recipe, "input": self.root / "source.DNG", "look": self.root / "look.cube"}
        sources["input"].write_bytes(b"read only input")
        sources["look"].write_bytes(b"read only look")
        self.document["input"]["path"] = str(sources["input"])
        self.document["edits"]["look"] = {"path": str(sources["look"])}
        for name, source in sources.items():
            for kind in ("direct", "normalized", "symlink", "hardlink"):
                for preview in (False, True):
                    with self.subTest(source=name, alias=kind, preview=preview):
                        alias = self.root / f"{name}-{kind}-{preview}.png"
                        if kind == "direct": alias = source
                        elif kind == "normalized": alias = source.parent / "unused" / ".." / source.name
                        else: self.create_link(alias, source, kind)
                        self.document["output"]["path"] = str(alias)
                        self.write_recipe()
                        original = {key: value.read_bytes() for key, value in sources.items()}
                        arguments = ["--recipe", self.recipe, "--json"]
                        if preview: arguments += ["--preview", alias]
                        self.envelope(self.run_cli(*arguments), "preview" if preview else "export", "invalid_argument")
                        self.assertEqual(original, {key: value.read_bytes() for key, value in sources.items()})

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

    def test_save_preset_and_sync_photo_edit_cli_subcommands(self):
        data_dir = self.root / "gui-data"
        preset_req = self.root / "preset_req.json"
        preset_req.write_text(
            json.dumps({
                "data_dir": str(data_dir),
                "name": "CLI Look",
                "is_raw": True,
                "processing_version": 3,
                "values": {"light.exposure": 0.5, "looks.reference": {"kind": "builtin", "id": "classic_chrome"}},
            }),
            encoding="utf-8",
        )
        # 1. --save-preset --json
        saved_env = self.envelope(self.run_cli("--save-preset", "--request", preset_req, "--json"), "save_preset")
        self.assertEqual(saved_env["result"]["action"], "created")
        self.assertEqual(saved_env["result"]["name"], "CLI Look")
        self.assertTrue((data_dir / "Presets" / "presets.json").is_file())

        # 2. Direct invocation without --json emits protocol_version=1 JSON
        preset_req2 = self.root / "preset_req2.json"
        preset_req2.write_text(
            json.dumps({
                "data_dir": str(data_dir),
                "name": "CLI Look Direct",
                "values": {"light.exposure": 0.25},
            }),
            encoding="utf-8",
        )
        direct_proc = self.run_cli("--save-preset", "--request", preset_req2)
        self.assertEqual(direct_proc.returncode, 0, direct_proc.stderr)
        direct_json = json.loads(direct_proc.stdout)
        self.assertEqual(direct_json["protocol_version"], 1)
        self.assertEqual(direct_json["action"], "created")

        # 3. Missing --request exits 2 (invalid_argument)
        bad_arg = self.run_cli("--save-preset", "--json")
        self.assertEqual(bad_arg.returncode, 2)
        self.envelope(bad_arg, "save_preset", "invalid_argument")

        # 4. Missing request file exits 3 (io_error)
        missing_req = self.run_cli("--save-preset", "--request", self.root / "missing.json", "--json")
        self.assertEqual(missing_req.returncode, 3)
        self.envelope(missing_req, "save_preset", "io_error")

        # 5. --sync-photo-edit on desktop OS or unsupported (4) on non-desktop
        photo = self.root / "sample.jpg"
        photo.write_bytes(b"fake-jpg")
        sync_req = self.root / "sync_req.json"
        sync_req.write_text(
            json.dumps({
                "data_dir": str(data_dir),
                "photo_path": str(photo),
                "is_raster": True,
                "adjustments": {"exposure": 0.75, "white_balance_mode": "relative", "temperature": 6200, "tint": 5},
                "film_id": "builtin:classic_chrome",
            }),
            encoding="utf-8",
        )
        sync_proc = self.run_cli("--sync-photo-edit", "--request", sync_req, "--json")
        if sys.platform in ("darwin", "win32"):
            sync_env = self.envelope(sync_proc, "sync_photo_edit")
            self.assertEqual(sync_env["result"]["action"], "created")
            self.assertEqual(sync_env["result"]["filmID"], "builtin:classic_chrome")
            self.assertTrue((data_dir / "Edits" / "edits.json").is_file())
        else:
            self.assertEqual(sync_proc.returncode, 4)
            self.envelope(sync_proc, "sync_photo_edit", "unsupported")

    def test_v20_print_transfer_save_preset_and_sync_photo_edit(self):
        dng_src = pathlib.Path(__file__).parent / "fixtures" / "linear-uncompressed.dng"
        sel_bands = {
            b: {"cyan": 0.0, "magenta": 0.0, "yellow": 0.0, "black": 0.0}
            for b in ("reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks")
        }
        sel_bands["reds"] = {"cyan": -12.0, "magenta": 6.5, "yellow": 4.0, "black": 0.0}
        bw_mixer = {"red": 20.0, "orange": 15.0, "yellow": 8.0, "green": -10.0, "aqua": -22.0, "blue": -30.0, "purple": 5.0, "magenta": 4.0}
        swatches = [{
            "src_hue": 21.0, "src_saturation": 0.30, "src_luminance": 0.70,
            "hue_shift": -2.5, "saturation_shift": -6.0, "luminance_shift": 1.5,
            "variance": -28.0, "range": 50.0, "hue_range": 45.0, "sat_range": 50.0, "lum_range": 50.0, "enabled": True,
        }]

        # 1. v20 raster recipe with defringe & all 29 v0.14.0 fields round-trips --print-transfer -> --save-preset
        photo_link = self.root / "input.dng"
        photo_link.write_bytes(dng_src.read_bytes())
        v20_recipe = self.root / "recipe_v20.json"
        v20_recipe.write_text(json.dumps({
            "schema_version": 20,
            "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
            "input": {"path": photo_link.name, "type": "raw"},
            "edits": {
                "exposure": {"mode": "preview", "ev": 0.25, "brightness": 1.0},
                "white_balance": {"mode": "camera"},
                "color": {
                    "calibration": {
                        "shadow_tint": -9.0, "red_hue": 6.0, "red_saturation": 11.0,
                        "green_hue": -4.0, "green_saturation": 3.5, "blue_hue": -8.0, "blue_saturation": 12.0,
                    },
                    "point_color": {"swatches": swatches},
                    "selective_color": {"method": "absolute", "bands": sel_bands},
                    "bw": {"enabled": True, "mixer": bw_mixer},
                },
                "detail": {"sharpening": 0.3, "luminance_v2": True, "sharpening_radius": 1.35, "sharpening_detail": 38.0, "sharpening_masking": 58.0},
                "effects": {
                    "texture": -0.18,
                    "grain_tone_curve": "negative_asymmetric",
                    "grain_format_preset": "120",
                    "halation": {"amount": 22.0, "threshold": 80.0, "radius": 42.0, "hue": -8.0},
                    "bloom": {"amount": 16.0, "threshold": 72.0, "radius": 48.0},
                },
                "lens_correction": {
                    "distortion": False, "tca": False, "vignetting": False, "auto_crop": True, "profile_id": None,
                    "defringe_purple_amount": 5.5, "defringe_purple_hue": 40.0,
                    "defringe_green_amount": 3.0, "defringe_green_hue": 60.0,
                },
            },
            "output": {"path": "unused.png", "format": "png"},
        }), encoding="utf-8")

        pt = self.envelope(self.run_cli("--recipe", v20_recipe, "--print-transfer", "--json"), "print_transfer")["result"]
        vals = pt["values"]
        self.assertAlmostEqual(vals["effects.texture"], -18.0, places=3)
        self.assertEqual(vals["effects.grain.tone_curve"], "negative_asymmetric")
        self.assertEqual(vals["effects.grain.format_preset"], "120")
        self.assertEqual(vals["detail.sharpening.luminance_v2"], True)
        self.assertAlmostEqual(vals["detail.sharpening.masking"], 58.0, places=3)
        self.assertAlmostEqual(vals["geometry.lens.defringe_purple_amount"], 5.5, places=3)

        data_dir = self.root / "gui-v20"
        preset_req = self.root / "v20_preset_req.json"
        preset_req.write_text(json.dumps({
            "data_dir": str(data_dir),
            "name": "CLI V20 Master",
            "is_raw": pt["source"]["is_raw"],
            "processing_version": pt["source"]["processing_version"],
            "values": vals,
        }), encoding="utf-8")
        preset_env = self.envelope(self.run_cli("--save-preset", "--request", preset_req, "--json"), "save_preset")
        self.assertEqual(preset_env["result"]["action"], "created")
        saved_vals = json.loads((data_dir / "Presets" / "presets.json").read_text(encoding="utf-8"))["presets"][0]["payload"]["values"]
        self.assertEqual(saved_vals["color.point_color"]["swatches"][0]["variance"], vals["color.point_color"]["swatches"][0]["variance"])

        # 2. --sync-photo-edit round-trip + explicit null reset + orthogonal preservation
        photo = self.root / "sample_v20.dng"
        photo.write_bytes(dng_src.read_bytes())
        sync_req = self.root / "v20_sync.json"
        sync_req.write_text(json.dumps({
            "data_dir": str(data_dir),
            "photo_path": str(photo),
            "is_raster": True,
            "film_id": "builtin:astia",
            "adjustments": {
                "texture": 25.0,
                "calibration": {"shadow_tint": -10.0},
                "point_color": {"swatches": swatches},
                "selective_color": {"method": "absolute", "bands": sel_bands},
                "bw": {"enabled": True, "mixer": bw_mixer},
                "sharpen_v2": {"luminance_v2": True, "masking": 60.0},
                "film_optics": {"halation_amount": 20.0},
                "photo_effects": {"grain_tone_curve": "negative_asymmetric", "grain_format_preset": "135"},
                "lens_correction": {"defringe_purple_amount": 4.5, "defringe_purple_hue": 42.0},
            },
        }), encoding="utf-8")
        sync_proc = self.run_cli("--sync-photo-edit", "--request", sync_req, "--json")
        if sys.platform not in ("darwin", "win32"):
            self.assertEqual(sync_proc.returncode, 4)
            return
        sync_env = self.envelope(sync_proc, "sync_photo_edit")
        photo_key = sync_env["result"]["photo_path"]
        edits_file = data_dir / "Edits" / "edits.json"
        doc = json.loads(edits_file.read_text(encoding="utf-8"))

        if sys.platform == "darwin":
            st = doc["records"][photo_key]["state"]["settings"]
            st["hdr"] = {"mode": "hdr"}
            st["aiDenoiseEnabled"] = True
            st["aiDenoiseStrength"] = 80.0
            st["lutID"] = "builtin:astia"
            st["futureUnknown"] = {"v": 15}
        else:
            st = doc["Records"][photo_key]["Settings"]
            st["HDR"] = {"Mode": "hdr"}
            st["AIDenoiseEnabled"] = True
            st["aiDenoiseStrength"] = 80.0
            st["lutID"] = "builtin:astia"
            st["FutureUnknown"] = {"v": 15}
        edits_file.write_text(json.dumps(doc), encoding="utf-8")

        reset_req = self.root / "v20_reset.json"
        reset_req.write_text(json.dumps({
            "data_dir": str(data_dir),
            "photo_path": str(photo),
            "is_raster": True,
            "adjustments": {
                "texture": 0.0,
                "calibration": None,
                "point_color": None,
                "selective_color": None,
                "bw": None,
                "sharpen_v2": {"luminance_v2": False, "radius": 1.0, "detail": 25.0, "masking": 0.0},
                "film_optics": None,
            },
        }), encoding="utf-8")
        self.envelope(self.run_cli("--sync-photo-edit", "--request", reset_req, "--json"), "sync_photo_edit")
        after = json.loads(edits_file.read_text(encoding="utf-8"))
        if sys.platform == "darwin":
            st2 = after["records"][photo_key]["state"]["settings"]
            for k in ("atmosphere", "cameraCalibration", "pointColor", "selectiveColor", "bwMixer", "sharpenV2", "filmOptics"):
                self.assertNotIn(k, st2)
            self.assertEqual(st2["hdr"], {"mode": "hdr"})
            self.assertTrue(st2["aiDenoiseEnabled"])
            self.assertEqual(st2["aiDenoiseStrength"], 80.0)
            self.assertEqual(st2["lutID"], "builtin:astia")
            self.assertEqual(st2["futureUnknown"], {"v": 15})
        else:
            st2 = after["Records"][photo_key]["Settings"]
            for k in ("Atmosphere", "CameraCalibration", "PointColor", "SelectiveColor", "BwMixer", "SharpenV2", "FilmOptics"):
                self.assertNotIn(k, st2)
            self.assertEqual(st2["HDR"], {"Mode": "hdr"})
            self.assertTrue(st2["AIDenoiseEnabled"])
            self.assertEqual(st2["aiDenoiseStrength"], 80.0)
            self.assertEqual(st2["lutID"], "builtin:astia")
            self.assertEqual(st2["FutureUnknown"], {"v": 15})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=str)
    parser.add_argument("--default-raw", type=str)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    if arguments.raw:
        if not pathlib.Path(arguments.raw).is_file():
            print(f"FAIL agent_commands: --raw does not exist: {arguments.raw}", file=sys.stderr)
            sys.exit(1)
        RAW = pathlib.Path(arguments.raw).resolve()
    else:
        env_raw = os.environ.get("RAWLAB_TEST_RAW", "")
        if env_raw and not pathlib.Path(env_raw).is_file():
            print(f"FAIL agent_commands: RAWLAB_TEST_RAW does not exist: {env_raw}", file=sys.stderr)
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
        print("SKIP agent_commands: default RAW sample not present and RAWLAB_TEST_RAW not set")
        sys.exit(77)
