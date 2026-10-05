import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
import PyOpenColorIO as ocio

from lutools.lutprep.contract import Contract
from lutools.lutprep.color import ColorSpaces, flog2_decode, flog2_encode, neutral_linear, srgb_encode
from lutools.lutprep.pipeline import LUTPipeline
from lutools.lutprep.bake import inspect_source, prepare


def manifest(input_space="linear-srgb", input_reference="scene",
             output_space="srgb", output_reference="display", **extra):
    return {
        "version": 1,
        "input": {"space": input_space, "reference": input_reference, "range": "full"},
        "output": {"space": output_space, "reference": output_reference, "range": "full"},
        "interpolation": "linear",
        **extra,
    }


def write_cube(path, function=lambda x: x, size=2, header="", domain=(0, 1)):
    lines = [header, f"LUT_3D_SIZE {size}",
             f"DOMAIN_MIN {domain[0]} {domain[0]} {domain[0]}",
             f"DOMAIN_MAX {domain[1]} {domain[1]} {domain[1]}"]
    for b in np.linspace(*domain, size):
        for g in np.linspace(*domain, size):
            for r in np.linspace(*domain, size):
                lines.append(" ".join(f"{v:.10g}" for v in function(np.array([r, g, b]))))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


class ContractTests(unittest.TestCase):
    def test_requires_explicit_input_and_output(self):
        for missing in ("input", "output"):
            data = manifest()
            del data[missing]
            with self.assertRaisesRegex(ValueError, missing):
                Contract.from_dict(data)

    def test_rejects_unknown_fields_and_signal_range(self):
        for data in (manifest(gamma="guess"), {**manifest(), "version": 2}):
            with self.assertRaises(ValueError):
                Contract.from_dict(data)
        data = manifest()
        data["input"]["range"] = "video"
        with self.assertRaisesRegex(ValueError, "range"):
            Contract.from_dict(data)

    def test_rejects_display_to_scene(self):
        with self.assertRaisesRegex(ValueError, "display.*scene"):
            Contract.from_dict(manifest("srgb", "display", "linear-srgb", "scene"))

    def test_round_trips_explicit_contract(self):
        data = manifest()
        self.assertEqual(Contract.from_dict(data).to_dict(), data)


class ColorTests(unittest.TestCase):
    def test_native_flog2_anchors_and_superwhites(self):
        values = np.array([-.005, 0, .0008, .18, .9, 2., 8.])
        np.testing.assert_allclose(flog2_decode(flog2_encode(values)), values, atol=2e-6)
        self.assertAlmostEqual(float(flog2_encode(2.)), .64144017, places=7)
        self.assertAlmostEqual(float(flog2_encode(0.)), .092864, places=7)

    def test_neutral_preserves_gray_and_highlight_order(self):
        self.assertAlmostEqual(float(neutral_linear(.1845)), .1845, places=7)
        self.assertTrue(np.all(np.diff(neutral_linear(np.array([0., 1., 2., 4.]))) > 0))

    def test_spaces_roundtrip_with_explicit_gamut_and_transfer(self):
        spaces = ColorSpaces()
        rgb = np.array([[.18, .18, .18], [.03, .4, .2], [2., .9, .5]])
        for name in spaces.names:
            with self.subTest(space=name):
                encoded = spaces.convert(rgb, "linear-srgb", name)
                actual = spaces.convert(encoded, name, "linear-srgb")
                np.testing.assert_allclose(actual, rgb, atol=3e-4)

    def test_slog3_gray_is_published_420_code(self):
        spaces = ColorSpaces()
        encoded = spaces.convert(np.full((1, 3), .18), "linear-srgb", "slog3-sgamut3-cine")
        np.testing.assert_allclose(encoded, 420 / 1023, atol=4e-5)

    def test_unknown_space_is_not_guessed(self):
        with self.assertRaisesRegex(ValueError, "Unknown color space"):
            ColorSpaces().convert(np.zeros((1, 3)), "unknown-camera", "srgb")


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / "identity.cube"
        write_cube(self.source)
        self.spaces = ColorSpaces()
        self.linear = np.array([[.01, .18, .8], [.5, .25, .03], [.18, .18, .18]])
        self.encoded = self.spaces.convert(self.linear, "linear-srgb", "flog2-fgamut")

    def pipeline(self, data):
        return LUTPipeline(self.source, Contract.from_dict(data))

    def test_scene_to_display_does_not_add_neutral_curve(self):
        result = self.pipeline(manifest()).evaluate(self.encoded)
        np.testing.assert_allclose(result, self.linear, atol=2e-5)

    def test_display_creative_lut_gets_neutral_before_lut(self):
        pipeline = self.pipeline(manifest("srgb", "display", "srgb", "display"))
        expected = srgb_encode(neutral_linear(self.linear))
        np.testing.assert_allclose(pipeline.evaluate(self.encoded), expected, atol=2e-5)

    def test_scene_output_gets_neutral_after_lut(self):
        pipeline = self.pipeline(manifest("linear-srgb", "scene", "linear-srgb", "scene"))
        np.testing.assert_allclose(pipeline.evaluate(self.encoded),
                                   srgb_encode(neutral_linear(self.linear)), atol=2e-5)

    def test_log_to_log_look_is_rendered_after_output_decoding(self):
        pipeline = self.pipeline(manifest("slog3-sgamut3-cine", "scene", "slog3-sgamut3-cine", "scene"))
        np.testing.assert_allclose(pipeline.evaluate(self.encoded),
                                   srgb_encode(neutral_linear(self.linear)), atol=5e-5)

    def test_ocio_reads_a_non_cube_one_dimensional_lut(self):
        source = self.source.with_suffix(".spi1d")
        source.write_text("Version 1\nFrom 0.0 1.0\nLength 2\nComponents 1\n{\n1.0\n0.0\n}\n")
        pipeline = LUTPipeline(source, Contract.from_dict(manifest("flog2-fgamut")))
        np.testing.assert_allclose(pipeline.evaluate(self.encoded), 1 - self.encoded, atol=2e-5)

    def test_legal_range_and_domain_are_independent(self):
        low, high = 64 / 1023, 940 / 1023
        write_cube(self.source, lambda x: (x - low) / (high - low), domain=(low, high))
        data = manifest()
        data["input"]["range"] = "legal10"
        np.testing.assert_allclose(self.pipeline(data).evaluate(self.encoded), self.linear, atol=2e-5)

    def test_legal_output_is_expanded_before_decoding(self):
        write_cube(self.source, lambda x: (64 + 876 * x) / 1023)
        data = manifest()
        data["output"]["range"] = "legal10"
        np.testing.assert_allclose(self.pipeline(data).evaluate(self.encoded), self.linear, atol=2e-5)

    def test_color_channels_are_not_transposed(self):
        write_cube(self.source, lambda x: x[[2, 0, 1]])
        np.testing.assert_allclose(self.pipeline(manifest()).evaluate(self.encoded),
                                   self.linear[:, [2, 0, 1]], atol=2e-5)

    def test_unknown_space_fails_at_import(self):
        with self.assertRaisesRegex(ValueError, "Unknown color space"):
            self.pipeline(manifest("looks-like-log"))

    def test_source_file_is_not_modified(self):
        original = self.source.read_bytes()
        self.pipeline(manifest()).evaluate(self.encoded)
        self.assertEqual(self.source.read_bytes(), original)

    def test_reloading_changed_source_does_not_reuse_ocio_file_cache(self):
        original = self.pipeline(manifest()).evaluate(self.encoded)
        write_cube(self.source, lambda x: 1 - x)
        changed = self.pipeline(manifest()).evaluate(self.encoded)
        np.testing.assert_allclose(changed, 1 - original, atol=2e-5)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = write_cube(self.root / "source.cube", lambda x: x[[2, 0, 1]])
        self.dest = self.root / "prepared.cube"
        self.contract = Contract.from_dict(manifest("flog2-fgamut"))

    def test_requires_manifest_for_untagged_source(self):
        with self.assertRaisesRegex(ValueError, "contract"):
            prepare(self.source, self.dest)
        self.assertFalse(self.dest.exists())

    def test_serialized_cube_has_native_metadata_and_channel_order(self):
        report = prepare(self.source, self.dest, self.contract, size=5)
        self.assertEqual(report["mode"], "baked")
        self.assertLess(report["error"]["max"], 1e-5)
        description = inspect_source(self.dest)
        self.assertTrue(description["canonical"])
        self.assertEqual(description["metadata"]["contract"], self.contract.to_dict())
        pipeline = LUTPipeline(self.dest, self.contract)
        points = np.array([[.1, .4, .8], [.9, .25, .3]])
        np.testing.assert_allclose(pipeline.evaluate(points), points[:, [2, 0, 1]], atol=2e-5)

    def test_legacy_canonical_passthrough_is_byte_identical(self):
        write_cube(self.source, header="#Gamma:F-Log2 to TEST\n#Gamut:F-Gamut to ITU-R BT.709")
        report = prepare(self.source, self.dest)
        self.assertEqual(report["mode"], "passthrough")
        self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())

    def test_canonical_metadata_cannot_hide_a_1d_shaper(self):
        self.source.write_text("#Gamma:F-Log2 to TEST\n#Gamut:F-Gamut to ITU-R BT.709\n"
                               "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        with self.assertRaisesRegex(ValueError, "contract"):
            prepare(self.source, self.dest)

    def test_contradictory_output_transfer_is_not_passthrough(self):
        write_cube(self.source, header="#Gamma:F-Log2 to TEST\n#Gamut:F-Gamut to ITU-R BT.709\n"
                                      "#OutputTransfer: PQ")
        self.assertFalse(inspect_source(self.source)["canonical"])

    def test_existing_destination_and_source_are_protected(self):
        self.dest.write_bytes(b"existing output")
        with self.assertRaises(FileExistsError):
            prepare(self.source, self.dest, self.contract)
        self.assertEqual(self.dest.read_bytes(), b"existing output")
        original = self.source.read_bytes()
        with self.assertRaises(ValueError):
            prepare(self.source, self.source, self.contract, force=True)
        self.assertEqual(self.source.read_bytes(), original)

    def test_failed_error_gate_keeps_existing_output_and_removes_temporary_file(self):
        self.dest.write_bytes(b"existing output")
        contract = Contract.from_dict(manifest("srgb", "display"))
        with self.assertRaisesRegex(ValueError, "error"):
            prepare(self.source, self.dest, contract, size=3, max_error=1e-6, force=True)
        self.assertEqual(self.dest.read_bytes(), b"existing output")
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["prepared.cube", "source.cube"])

    def test_approximation_must_be_explicit_and_is_reported(self):
        contract = Contract.from_dict(manifest("srgb", "display"))
        report = prepare(self.source, self.dest, contract, size=3, max_error=1e-6,
                         allow_approximation=True)
        self.assertFalse(report["within_tolerance"])
        self.assertGreater(report["error"]["max"], 1e-6)

    def test_cli_exits_nonzero_on_unknown_contract(self):
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "prepare",
                                 str(self.source), str(self.dest)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contract", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_cli_reads_contract_and_reports_result(self):
        contract_file = self.root / "source.json"
        contract_file.write_text(json.dumps(self.contract.to_dict()))
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "prepare",
                                 str(self.source), str(self.dest), "--contract", str(contract_file),
                                 "--size", "5"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "baked")

    def test_failed_cli_error_gate_still_reports_measurement_without_writing_output(self):
        contract_file = self.root / "source.json"
        contract_file.write_text(json.dumps(manifest("srgb", "display")))
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "prepare",
                                 str(self.source), str(self.dest), "--contract", str(contract_file),
                                 "--size", "3"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stdout.strip().startswith("{"), result.stderr)
        self.assertFalse(json.loads(result.stdout)["within_tolerance"])
        self.assertFalse(self.dest.exists())

    def test_custom_ocio_config_path_is_resolved_but_not_embedded(self):
        config = ocio.Config.CreateRaw()
        reference = ocio.ColorSpace(name="Reference")
        custom = ocio.ColorSpace(name="Half Linear")
        custom.setTransform(ocio.MatrixTransform(matrix=[2, 0, 0, 0, 0, 2, 0, 0,
                                                        0, 0, 2, 0, 0, 0, 0, 1]),
                            ocio.COLORSPACE_DIR_TO_REFERENCE)
        config.addColorSpace(reference)
        config.addColorSpace(custom)
        config_file = self.root / "custom.ocio"
        config_file.write_text(config.serialize())
        data = manifest("ocio:Half Linear", "scene", "ocio:Half Linear", "scene",
                        ocio={"config": str(config_file), "reference_space": "Reference"})
        contract = Contract.from_dict(data)
        write_cube(self.source)
        pipeline = LUTPipeline(self.source, contract)
        linear = np.array([[.18, .3, .6]])
        encoded = ColorSpaces().convert(linear, "linear-srgb", "flog2-fgamut")
        np.testing.assert_allclose(pipeline.evaluate(encoded), srgb_encode(neutral_linear(linear)), atol=2e-5)
        report = prepare(self.source, self.dest, contract, size=5, allow_approximation=True)
        self.assertEqual(report["contract"]["ocio"]["config"], "custom.ocio")
        self.assertNotIn(str(self.root), self.dest.read_text())

    def test_hard_link_to_source_is_protected_even_with_force(self):
        import os
        os.link(self.source, self.dest)
        original = self.source.read_bytes()
        with self.assertRaisesRegex(ValueError, "different"):
            prepare(self.source, self.dest, self.contract, force=True)
        self.assertEqual(self.source.read_bytes(), original)

    def test_custom_ocio_data_space_cannot_be_a_color_reference(self):
        config = ocio.Config.CreateRaw()
        path = self.root / "raw.ocio"
        path.write_text(config.serialize())
        with self.assertRaisesRegex(ValueError, "reference_space"):
            ColorSpaces(path, "raw")
        config.addColorSpace(ocio.ColorSpace(name="Reference"))
        path.write_text(config.serialize())
        with self.assertRaisesRegex(ValueError, "data space"):
            ColorSpaces(path, "Reference").convert(np.zeros((1, 3)), "ocio:raw", "srgb")


if __name__ == "__main__":
    unittest.main()
