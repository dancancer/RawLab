"""Recipe v4/v5 schema and CLI normalization contract tests."""
import argparse
import copy
import json
import pathlib
import struct
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "docs" / "edit-json-v4.schema.json"
EXAMPLE_PATH = ROOT / "examples" / "edit-recipes" / "complete-v4.json"
try:
    import jsonschema
except ImportError:  # pragma: no cover - exercised by environments without the optional module
    jsonschema = None


class EditRecipeSchema(unittest.TestCase):
    def test_v7_x3f_identity(self):
        schema = json.loads((ROOT / "docs/edit-json-v7.schema.json").read_text())
        document = json.loads((ROOT / "examples/edit-recipes/x3f-v7.json").read_text())
        for mode in ("normal-v1", "legacy"):
            document["x3f_mode"] = mode
            normalized = self.normalize(document)
            self.assertEqual(normalized["x3f_mode"], mode)
            if jsonschema:
                jsonschema.Draft202012Validator.check_schema(schema)
                jsonschema.Draft202012Validator(schema).validate(normalized)
        for mode in (None, 1, "future"):
            invalid = copy.deepcopy(document)
            invalid["x3f_mode"] = mode
            self.reject(invalid, "x3f_mode")
        del document["x3f_mode"]
        self.reject(document, "x3f_mode")
        document["x3f_mode"] = "normal-v1"
        document["input"]["type"] = "raster"
        self.reject(document, "X3F raw input")
        document["input"]["type"] = "raw"
        document["schema_version"] = 5
        self.reject(document, "x3f_mode")

    def test_v6_hdr_schema_and_strict_groups(self):
        schema=json.loads((ROOT / "docs/edit-json-v6.schema.json").read_text())
        document=json.loads((ROOT / "examples/edit-recipes/hdr-v6.json").read_text())
        capabilities=subprocess.run([str(CLI),"--capabilities","--json"],capture_output=True,text=True,check=True)
        if 6 not in json.loads(capabilities.stdout)["result"]["recipe_versions"]:
            self.skipTest("CLI runtime has no HDR v6 capability")
        normalized=self.normalize(document)
        if jsonschema:
            jsonschema.Draft202012Validator.check_schema(schema)
            jsonschema.Draft202012Validator(schema).validate(document)
            jsonschema.Draft202012Validator(schema).validate(normalized)
        for group in ("look","hsl","detail","effects","denoise","lens_correction","color_grading"):
            invalid=copy.deepcopy(document)
            invalid["edits"][group]={}
            self.reject(invalid,"edits."+group)
            if jsonschema:
                self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
        for field,value in (("relative_temperature",1999),("relative_tint",151),("temperature_kelvin",6500)):
            invalid=copy.deepcopy(document)
            invalid["edits"]["white_balance"][field]=value
            self.reject(invalid,field)
            if jsonschema:
                self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rawlab-edit-v4-schema-")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.recipe = self.root / "edit.json"

    def run_cli(self, document):
        self.recipe.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        return subprocess.run(
            [str(CLI), "--recipe", str(self.recipe), "--print-recipe", "--json"],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def normalize(self, document):
        process = self.run_cli(document)
        try:
            envelope = json.loads(process.stdout)
        except json.JSONDecodeError as failure:
            self.fail(f"stdout must be one JSON object: {process.stdout!r}; stderr={process.stderr!r}; {failure}")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(set(envelope), {"protocol_version", "command", "ok", "result", "error"})
        self.assertEqual(envelope["protocol_version"], 1)
        self.assertEqual(envelope["command"], "validate_recipe")
        self.assertTrue(envelope["ok"], envelope)
        self.assertIsNone(envelope["error"])
        return envelope["result"]

    def reject(self, document, field):
        process = self.run_cli(document)
        self.assertNotEqual(process.returncode, 0, process.stderr)
        envelope = json.loads(process.stdout)
        self.assertFalse(envelope["ok"])
        self.assertEqual(envelope["error"]["code"], "invalid_recipe")
        self.assertIsNone(envelope["error"]["status"])
        self.assertIn(field, envelope["error"]["message"])

    def test_v5_tone_controls(self):
        schema = json.loads((ROOT / "docs" / "edit-json-v5.schema.json").read_text())
        document = self.full()
        document["schema_version"] = 5
        document["processing"] = {"family": "rawlab", "version": 2, "quality": "standard"}
        document["edits"]["tone"].update(black_point=.25, white_point=-.5)
        document["edits"]["color"] = {"vibrance": .75}
        normalized = self.normalize(document)
        for group, field, expected in (("tone", "black_point", .25), ("tone", "white_point", -.5), ("color", "vibrance", .75)):
            self.assertEqual(normalized["edits"][group][field], expected)
            for value in (-1.01, 1.01, True, "0", None):
                invalid = copy.deepcopy(document)
                invalid["edits"][group][field] = value
                self.reject(invalid, f"edits.{group}.{field}")
                if jsonschema:
                    self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
        if jsonschema:
            jsonschema.Draft202012Validator(schema).validate(document)
            jsonschema.Draft202012Validator(schema).validate(normalized)
        invalid = copy.deepcopy(document)
        invalid["edits"]["color"]["unknown"] = 0
        self.reject(invalid, "edits.color.unknown")
        document["schema_version"] = 4
        del document["processing"]
        self.reject(document, "edits.color")
        del document["edits"]["color"]
        self.reject(document, "edits.tone.black_point")

    def test_v5_atmosphere(self):
        schema = json.loads((ROOT / "docs" / "edit-json-v5.schema.json").read_text())
        document = self.full()
        document["schema_version"] = 5
        document["processing"] = {"family": "rawlab", "version": 2, "quality": "standard"}
        document["edits"]["effects"].update(clarity=.625, dehaze=-.375)
        normalized = self.normalize(document)
        for field, expected in (("clarity", .625), ("dehaze", -.375)):
            self.assertEqual(normalized["edits"]["effects"][field], expected)
            for value in (-1.01, 1.01, True, "0", None):
                invalid = copy.deepcopy(document)
                invalid["edits"]["effects"][field] = value
                self.reject(invalid, f"edits.effects.{field}")
                if jsonschema:
                    self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
        if jsonschema:
            jsonschema.Draft202012Validator(schema).validate(document)
            jsonschema.Draft202012Validator(schema).validate(normalized)
        document["edits"]["effects"].update(clarity=0, dehaze=0)
        normalized = self.normalize(document)
        self.assertNotIn("clarity", normalized["edits"]["effects"])
        self.assertNotIn("dehaze", normalized["edits"]["effects"])
        document["schema_version"] = 4
        del document["processing"]
        self.reject(document, "edits.effects.clarity")

    def test_v5_color_grading(self):
        schema = json.loads((ROOT / "docs" / "edit-json-v5.schema.json").read_text())
        document = self.full()
        document.update(schema_version=5, processing={"family": "rawlab", "version": 2, "quality": "standard"})
        document["edits"]["color_grading"] = {
            "shadows": {"hue": 220, "saturation": 75},
            "midtones": {"hue": 110, "saturation": 0},
            "highlights": {"hue": 35.25, "saturation": 16.5},
        }
        normalized = self.normalize(document)
        self.assertEqual(normalized["edits"]["color_grading"], document["edits"]["color_grading"])
        if jsonschema:
            jsonschema.Draft202012Validator(schema).validate(document)
            jsonschema.Draft202012Validator(schema).validate(normalized)
        for zone in ("shadows", "midtones", "highlights"):
            for field, bad_values in (("hue", (-.000001, 360, True, "0", None)),
                                      ("saturation", (-.000001, 100.000001, True, "0", None))):
                for value in bad_values:
                    invalid = copy.deepcopy(document)
                    invalid["edits"]["color_grading"][zone][field] = value
                    self.reject(invalid, f"edits.color_grading.{zone}.{field}")
                    if jsonschema:
                        self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
                missing = copy.deepcopy(document)
                del missing["edits"]["color_grading"][zone][field]
                self.reject(missing, f"edits.color_grading.{zone}.{field}")
                if jsonschema:
                    self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(missing))
        document["schema_version"] = 4
        del document["processing"]
        self.reject(document, "edits.color_grading")

    def test_v5_tone_curve(self):
        schema = json.loads((ROOT / "docs" / "edit-json-v5.schema.json").read_text())
        document = self.full()
        document.update(schema_version=5, processing={"family": "rawlab", "version": 2, "quality": "standard"})
        document["edits"]["tone"].update(s_curve=0, curve={"mode": "custom", "points": [[0, 0], [.25, .12], [.75, .88], [1, 1]]})
        normalized = self.normalize(document)
        self.assertEqual(normalized["edits"]["tone"]["curve"], document["edits"]["tone"]["curve"])
        if jsonschema:
            jsonschema.Draft202012Validator(schema).validate(normalized)
        for curve in (
            {"mode": "future", "points": []}, {"mode": "custom", "points": [[0, 0]]},
            {"mode": "custom", "points": [[0, 0], [True, 1]]},
            {"mode": "custom", "points": [[0, 0], [1, 1, 1]]},
            {"mode": "custom", "points": [[0, 0], [1.000001, 1]]},
            {"mode": "legacy", "points": [[0, 0], [1, 1]]},
            {"mode": "custom", "points": [[0, 0], [1, 1]], "channel": "red"},
        ):
            invalid = copy.deepcopy(document)
            invalid["edits"]["tone"]["curve"] = curve
            self.reject(invalid, "edits.tone.curve")
            if jsonschema:
                self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
        for points in ([[0, .1], [1, 1]], [[0, 0], [.5, .7], [.5, .9], [1, 1]],
                       [[0, 0], [.5, .7], [.7, .5], [1, 1]]):
            invalid = copy.deepcopy(document)
            invalid["edits"]["tone"]["curve"]["points"] = points
            self.reject(invalid, "edits.tone.curve")
        invalid = copy.deepcopy(document)
        invalid["edits"]["tone"]["s_curve"] = .1
        self.reject(invalid, "s_curve")
        if jsonschema:
            self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(invalid))
        document["schema_version"] = 4
        del document["processing"]
        self.reject(document, "edits.tone.curve")

    def test_processing_identity(self):
        schema = json.loads((ROOT / "docs" / "edit-json-v5.schema.json").read_text())
        document = self.full()
        document["schema_version"] = 5
        for version in (1, 2):
            document["processing"] = {"family": "rawlab", "version": version, "quality": "standard"}
            normalized = self.normalize(document)
            self.assertEqual(normalized["processing"], document["processing"])
            self.assertEqual(normalized["schema_version"], 5)
            if jsonschema:
                jsonschema.Draft202012Validator(schema).validate(normalized)
        output = self.root / "protected.png"
        output.write_bytes(b"existing output")
        document["output"]["path"] = str(output)
        for identity in (
            None, {}, {"family": "other", "version": 1, "quality": "standard"},
            {"family": "rawlab", "version": 99, "quality": "standard"},
            {"family": "rawlab", "version": True, "quality": "standard"},
            {"family": "rawlab", "version": 1, "quality": "fast"},
            {"family": "rawlab", "version": 1},
            {"family": "rawlab", "version": 1, "quality": "standard", "extra": 0},
        ):
            document["processing"] = identity
            self.reject(document, "processing")
            if jsonschema:
                self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(document))
            process = subprocess.run([str(CLI), "--recipe", str(self.recipe), "--json"],
                                     capture_output=True, text=True, timeout=120)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(json.loads(process.stdout)["error"]["code"], "invalid_recipe")
            self.assertEqual(output.read_bytes(), b"existing output")
        del document["processing"]
        self.reject(document, "processing")
        for version in range(1, 5):
            old = self.base()
            old["schema_version"] = version
            self.assertNotIn("processing", self.normalize(old))
            old["processing"] = {"family": "rawlab", "version": 1, "quality": "standard"}
            self.reject(old, "processing")

    @staticmethod
    def base():
        return {
            "schema_version": 4,
            "input": {"path": "photo.DNG"},
            "edits": {"exposure": {"mode": "scene"}},
            "output": {"path": "edited.png", "format": "png"},
        }

    @staticmethod
    def full():
        document = EditRecipeSchema.base()
        document["edits"]["exposure"] = {"mode": "scene", "ev": -2.5, "brightness": 1.25}
        document["edits"].update({
            "white_balance": {"mode": "temperature", "temperature_kelvin": 4200.5, "tint": -18.5},
            "look": {"path": "looks/test.cube", "strength": 1.25},
            "geometry": {
                "crop": {"x": 0.125, "y": 0.0625, "width": 0.75, "height": 0.875},
                "quarter_turns": 3, "flip_horizontal": True, "flip_vertical": True,
                "straighten_degrees": -12.5,
                "perspective": {"horizontal": -0.625, "vertical": 0.75},
            },
            "tone": {"contrast": 1.25, "saturation": 0.75, "highlights": -0.25, "shadows": 0.625, "s_curve": -0.5},
            "detail": {"sharpening": 1.25},
            "hsl": {
                "hue": [-100, 42.5, 0, 0, 0, 0, 0, 0],
                "saturation": [55.5, -100, 0, 0, 0, 0, 0, 0],
                "lightness": [-42.5, 100, 0, 0, 0, 0, 0, 0],
            },
            "effects": {
                "vignette_amount": -75.5, "vignette_midpoint": 12.5,
                "vignette_roundness": 66.5, "vignette_feather": 87.5,
                "vignette_highlights": 92.5, "grain_amount": 77.5,
                "grain_size": 12.5, "grain_roughness": 87.5,
            },
            "denoise": {
                "raw_level": 2, "chroma_mode": 2,
                "wavelet": {"enabled": True, "luma": 87.5, "chroma": 12.5, "coarse": 62.5},
            },
            "lens_correction": {
                "distortion": True, "tca": True, "auto_crop": False, "profile_id": "catalog-id",
            },
        })
        document["output"]["jpeg_quality"] = 1
        document["output"]["size"] = {"mode": "limit_long_edge", "long_edge": 4294967295}
        return document

    @staticmethod
    def raster():
        document = copy.deepcopy(EditRecipeSchema.full())
        document["input"] = {"path": "photo.png", "type": "raster"}
        document["edits"]["exposure"]["mode"] = "sensor"
        document["edits"]["white_balance"] = {"mode": "none"}
        document["edits"]["denoise"]["raw_level"] = 0
        document["edits"]["lens_correction"] = {
            "distortion": False, "tca": False, "auto_crop": False, "profile_id": None,
        }
        return document

    @staticmethod
    def float32_document(value):
        if isinstance(value, float):
            return struct.unpack("!f", struct.pack("!f", value))[0]
        if isinstance(value, dict):
            return {key: EditRecipeSchema.float32_document(item) for key, item in value.items()}
        if isinstance(value, list):
            return [EditRecipeSchema.float32_document(item) for item in value]
        return value

    def assert_float32_normalized(self, normalized, document):
        expected = copy.deepcopy(document)
        expected["input"].setdefault("type", "raw")
        self.assertEqual(self.float32_document(normalized), self.float32_document(expected))

    @unittest.skipUnless(jsonschema is not None, "jsonschema module unavailable; schema validation skipped")
    def test_schema_and_example_are_valid(self):
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator.check_schema(schema)
        validator = jsonschema.Draft202012Validator(schema)
        validator.validate(json.loads(EXAMPLE_PATH.read_text(encoding="utf-8")))
        validator.validate(self.base())
        validator.validate(self.full())
        validator.validate(self.raster())

    def test_defaults_are_normalized_and_schema_compatible(self):
        normalized = self.normalize(self.base())
        self.assertEqual(normalized["schema_version"], 4)
        self.assertEqual(normalized["input"], {"path": "photo.DNG", "type": "raw"})
        self.assertEqual(normalized["edits"]["look"], {"path": None, "strength": 1})
        self.assertEqual(normalized["edits"]["tone"], {
            "contrast": 1, "saturation": 1, "highlights": 0, "shadows": 0, "s_curve": 0,
        })
        self.assertEqual(normalized["edits"]["detail"], {"sharpening": 0})
        self.assertEqual(normalized["edits"]["hsl"], {
            "hue": [0] * 8, "saturation": [0] * 8, "lightness": [0] * 8,
        })
        self.assertEqual(normalized["edits"]["effects"], {
            "vignette_amount": 0, "vignette_midpoint": 50, "vignette_roundness": 0,
            "vignette_feather": 50, "vignette_highlights": 0, "grain_amount": 0,
            "grain_size": 25, "grain_roughness": 50,
        })
        self.assertEqual(normalized["edits"]["denoise"], {
            "raw_level": 0, "chroma_mode": 0,
            "wavelet": {"enabled": False, "luma": 0, "chroma": 46, "coarse": 50},
        })
        self.assertEqual(normalized["edits"]["lens_correction"], {
            "distortion": False, "tca": False, "auto_crop": True, "profile_id": None,
        })
        if jsonschema is not None:
            jsonschema.Draft202012Validator(json.loads(SCHEMA_PATH.read_text())).validate(normalized)

    def test_complete_recipe_round_trips_all_effective_values(self):
        document = self.full()
        normalized = self.normalize(document)
        self.assert_float32_normalized(normalized, document)
        self.assertEqual(self.normalize(normalized), normalized)

    def test_raster_defaults_and_complete_recipe_round_trip(self):
        minimal = {
            "schema_version": 4,
            "input": {"path": "photo.png", "type": "raster"},
            "edits": {"exposure": {"mode": "sensor"}},
            "output": {"path": "edited.png", "format": "png"},
        }
        normalized = self.normalize(minimal)
        self.assertEqual(normalized["input"], {"path": "photo.png", "type": "raster"})
        self.assertEqual(normalized["edits"]["exposure"]["mode"], "sensor")
        self.assertEqual(normalized["edits"]["white_balance"], {"mode": "none"})
        self.assertEqual(normalized["edits"]["denoise"]["raw_level"], 0)
        self.assertEqual(normalized["edits"]["lens_correction"], {
            "distortion": False, "tca": False, "auto_crop": True, "profile_id": None,
        })
        if jsonschema is not None:
            jsonschema.Draft202012Validator(json.loads(SCHEMA_PATH.read_text())).validate(normalized)

        document = self.raster()
        normalized = self.normalize(document)
        self.assert_float32_normalized(normalized, document)
        self.assertEqual(self.normalize(normalized), normalized)

    def test_raster_constraints_and_legacy_input_type_rejection(self):
        def assert_invalid(document, field):
            if jsonschema is not None:
                schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
                self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(document))
            self.reject(document, field)

        for name, path, value, field in (
            ("exposure", ("edits", "exposure", "mode"), "scene", "Raster inputs"),
            ("white balance", ("edits", "white_balance", "mode"), "camera", "Raster edits.white_balance.mode"),
            ("raw FBDD", ("edits", "denoise", "raw_level"), 1, "Raster inputs"),
            ("lens distortion", ("edits", "lens_correction", "distortion"), True, "Raster inputs"),
            ("lens TCA", ("edits", "lens_correction", "tca"), True, "Raster inputs"),
            ("lens profile", ("edits", "lens_correction", "profile_id"), "catalog-id", "Raster inputs"),
        ):
            with self.subTest(name=name):
                candidate = self.raster()
                target = candidate
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                assert_invalid(candidate, field)

        raw_wb_none = self.base()
        raw_wb_none["input"]["type"] = "raw"
        raw_wb_none["edits"]["white_balance"] = {"mode": "none"}
        assert_invalid(raw_wb_none, "edits.white_balance.mode")

        for version in (1, 2, 3):
            with self.subTest(version=version):
                candidate = self.base()
                candidate["schema_version"] = version
                candidate["input"]["type"] = "raw"
                candidate["edits"] = {"exposure": {"mode": "scene"}}
                if jsonschema is not None:
                    legacy = json.loads((ROOT / "docs" / f"edit-json-v{version}.schema.json").read_text(encoding="utf-8"))
                    self.assertFalse(jsonschema.Draft202012Validator(legacy).is_valid(candidate))
                self.reject(candidate, "input.type")

    def test_all_new_boundaries_are_accepted(self):
        document = self.full()
        controls = [
            ("look.strength", ("edits", "look", "strength"), (0, 2)),
            ("tone.contrast", ("edits", "tone", "contrast"), (0, 2)),
            ("tone.saturation", ("edits", "tone", "saturation"), (0, 2)),
            ("tone.highlights", ("edits", "tone", "highlights"), (-1, 1)),
            ("tone.shadows", ("edits", "tone", "shadows"), (-1, 1)),
            ("tone.s_curve", ("edits", "tone", "s_curve"), (-1, 1)),
            ("detail.sharpening", ("edits", "detail", "sharpening"), (0, 2)),
            ("effects.vignette_amount", ("edits", "effects", "vignette_amount"), (-100, 100)),
            ("effects.vignette_midpoint", ("edits", "effects", "vignette_midpoint"), (0, 100)),
            ("effects.vignette_roundness", ("edits", "effects", "vignette_roundness"), (-100, 100)),
            ("effects.vignette_feather", ("edits", "effects", "vignette_feather"), (0, 100)),
            ("effects.vignette_highlights", ("edits", "effects", "vignette_highlights"), (0, 100)),
            ("effects.grain_amount", ("edits", "effects", "grain_amount"), (0, 100)),
            ("effects.grain_size", ("edits", "effects", "grain_size"), (0, 100)),
            ("effects.grain_roughness", ("edits", "effects", "grain_roughness"), (0, 100)),
            ("denoise.raw_level", ("edits", "denoise", "raw_level"), (0, 2)),
            ("denoise.chroma_mode", ("edits", "denoise", "chroma_mode"), (0, 2)),
            ("wavelet.luma", ("edits", "denoise", "wavelet", "luma"), (0, 100)),
            ("wavelet.chroma", ("edits", "denoise", "wavelet", "chroma"), (0, 100)),
            ("wavelet.coarse", ("edits", "denoise", "wavelet", "coarse"), (0, 100)),
        ]
        for name, path, values in controls:
            for value in values:
                with self.subTest(name=name, value=value):
                    candidate = copy.deepcopy(document)
                    target = candidate
                    for key in path[:-1]:
                        target = target[key]
                    target[path[-1]] = value
                    normalized = self.normalize(candidate)
                    target = normalized
                    for key in path:
                        target = target[key]
                    self.assertEqual(target, value)
        for axis in ("hue", "saturation", "lightness"):
            for value in (-100, 100):
                candidate = copy.deepcopy(document)
                candidate["edits"]["hsl"][axis] = [value] * 8
                self.assertEqual(self.normalize(candidate)["edits"]["hsl"][axis], [value] * 8)

    def test_profile_id_null_and_unknown_fields(self):
        candidate = copy.deepcopy(self.base())
        candidate["edits"] = {"exposure": {"mode": "scene"}, "lens_correction": {"profile_id": None}}
        self.assertIsNone(self.normalize(candidate)["edits"]["lens_correction"]["profile_id"])
        for candidate, field in (
            ({**self.base(), "future": True}, "recipe.future"),
            ({**self.base(), "edits": {"exposure": {"mode": "scene"}, "tone": {"future": 0}}}, "edits.tone.future"),
            ({**self.base(), "edits": {"exposure": {"mode": "scene"}, "hsl": {"hue": [0]}}}, "edits.hsl.hue"),
        ):
            with self.subTest(field=field):
                self.reject(candidate, field)

    def test_v3_rejects_v4_fields(self):
        candidate = self.base()
        candidate["schema_version"] = 3
        candidate["edits"]["tone"] = {"contrast": 1}
        self.reject(candidate, "edits.tone")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    unittest.main(argv=[__file__, *remaining])
