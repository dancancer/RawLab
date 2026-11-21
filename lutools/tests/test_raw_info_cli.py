"""Metadata-only RAW info regressions using read-only fixtures and temporary files."""
import argparse
import json
import math
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


class RawInfoCLI(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rawlab-info-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def run_cli(self, *arguments, cwd=None):
        return subprocess.run([str(CLI), *map(str, arguments)], cwd=cwd,
                              capture_output=True, text=True, encoding="utf-8", timeout=60)

    def envelope(self, process, error=None, command="info", status=None):
        try:
            value = json.loads(process.stdout)
        except json.JSONDecodeError as failure:
            self.fail(f"stdout must be one JSON object: {process.stdout!r}; stderr={process.stderr!r}; {failure}")
        self.assertIsInstance(value, dict)
        self.assertEqual(set(value), {"protocol_version", "command", "ok", "result", "error"})
        self.assertEqual(type(value["protocol_version"]), int)
        self.assertEqual(value["protocol_version"], 1)
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
            allowed = {error} if isinstance(error, str) else set(error)
            self.assertIn(value["error"]["code"], allowed)
            self.assertIsInstance(value["error"]["message"], str)
            self.assertTrue(value["error"]["message"])
            if status is not None:
                self.assertEqual(type(value["error"]["status"]), int)
                self.assertEqual(value["error"]["status"], status)
        return value

    def fixture(self, name):
        if FIXTURES is None or not (FIXTURES / name).is_file():
            self.skipTest(f"synthetic fixture {name} not provided")
        return FIXTURES / name

    def assert_metadata(self, result, path):
        self.assertEqual(set(result), {
            "input_path", "camera", "lens", "identified_size", "rendered_size",
            "capture", "as_shot_white_balance",
        })
        reported_path = pathlib.Path(result["input_path"])
        self.assertTrue(reported_path.is_absolute())
        self.assertEqual(reported_path.resolve(), path.resolve())
        self.assertEqual(set(result["camera"]), {"make", "model"})
        self.assertEqual(set(result["lens"]), {"model", "focal_length_mm"})
        for text in (result["camera"]["make"], result["camera"]["model"], result["lens"]["model"]):
            if text is not None:
                self.assertIsInstance(text, str)
                self.assertTrue(text)
        self.assertEqual(set(result["identified_size"]), {"width", "height", "orientation"})
        for dimension in ("width", "height"):
            self.assertEqual(type(result["identified_size"][dimension]), int)
            self.assertGreater(result["identified_size"][dimension], 0)
        orientation = result["identified_size"]["orientation"]
        if orientation is not None:
            self.assertEqual(type(orientation), int)
            self.assertIn(orientation, range(8))
        self.assertIsNone(result["rendered_size"])
        self.assertEqual(result["as_shot_white_balance"], {"temperature_kelvin": None, "tint": None})
        self.assertEqual(set(result["capture"]), {
            "iso", "aperture", "shutter_seconds", "exposure_bias_ev", "baseline_exposure_ev",
        })
        self.assertIsNone(result["capture"]["exposure_bias_ev"])
        for number in (result["lens"]["focal_length_mm"], result["capture"]["iso"],
                       result["capture"]["aperture"], result["capture"]["shutter_seconds"]):
            if number is not None:
                self.assertIn(type(number), (int, float))
                self.assertTrue(math.isfinite(number))
                self.assertGreater(number, 0)
        baseline = result["capture"]["baseline_exposure_ev"]
        if baseline is not None:
            self.assertIn(type(baseline), (int, float))
            self.assertTrue(math.isfinite(baseline))

    def test_capabilities_advertises_info(self):
        result = self.envelope(self.run_cli("--capabilities", "--json"), command="capabilities")["result"]
        self.assertIn("info", result["commands"])

    def test_missing_file_has_io_status(self):
        missing = self.root / "missing.DNG"
        for arguments in (("--info", missing, "--json"), ("--json", "--info", missing), ("--info", missing)):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), "io_error", status=3)

    def test_random_invalid_input_has_structured_error(self):
        invalid = self.root / "invalid.DNG"
        invalid.write_bytes(b"This is not a RAW image.\n" * 4096)
        self.envelope(self.run_cli("--info", invalid, "--json"), {"unsupported", "processing_error"})

    def test_missing_duplicate_and_unknown_arguments(self):
        missing = self.root / "missing.DNG"
        for arguments in (
            ("--info",), ("--info", "--json"), ("--json", "--info"),
            ("--info", "", "--json"),
            ("--info", missing, "--info", missing, "--json"),
            ("--info", missing, "--json", "--json"),
            ("--info", missing, "--unknown", "--json"),
            ("--info", missing, "unexpected.DNG", "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), "invalid_argument")

    def test_conflicting_commands(self):
        missing = self.root / "missing.DNG"
        for arguments in (
            ("--info", missing, "--recipe", "missing.json", "--json"),
            ("--recipe", "missing.json", "--info", missing, "--json"),
            ("--info", missing, "--print-recipe", "--json"),
            ("--capabilities", "--info", missing, "--json"),
        ):
            with self.subTest(arguments=arguments):
                self.envelope(self.run_cli(*arguments), "invalid_argument", command=None)

    def test_info_option_as_legacy_output_operand(self):
        for option in ("-o", "--output"):
            with self.subTest(option=option):
                process = self.run_cli(self.root / "missing.ARW", "--no-lut", option, "--info", cwd=self.root)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("Processing failed", process.stderr)
                self.assertNotIn('"protocol_version"', process.stdout)

    def test_synthetic_rotated_uncompressed_and_jxl_sizes(self):
        for name in ("linear-uncompressed.dng", "linear-jxl.dng"):
            path = self.fixture(name)
            with self.subTest(name=name):
                result = self.envelope(self.run_cli("--info", path, "--json"))["result"]
                self.assert_metadata(result, path)
                # Fixture storage is 32x24 with orientation 6; rendered 24x32 is not predicted.
                self.assertEqual(result["identified_size"], {"width": 32, "height": 24, "orientation": 6})
                self.assertEqual(result["camera"]["make"], "RawLab")
                self.assertIsNone(result["capture"]["baseline_exposure_ev"])

    def test_required_unsupported_opcode_does_not_require_unpack(self):
        path = self.fixture("linear-jxl-required-unknown.dng")
        result = self.envelope(self.run_cli("--json", "--info", path))["result"]
        self.assert_metadata(result, path)
        self.assertEqual(result["identified_size"], {"width": 32, "height": 24, "orientation": 6})

    def test_synthetic_lens_metadata(self):
        path = self.fixture("linear-lens.dng")
        result = self.envelope(self.run_cli("--info", path))["result"]
        self.assert_metadata(result, path)
        self.assertEqual(result["camera"], {"make": "RawLab", "model": "Test Camera"})
        self.assertEqual(result["lens"]["model"], "Test 24mm f/2.8")
        self.assertEqual(result["lens"]["focal_length_mm"], 24)
        self.assertAlmostEqual(result["capture"]["aperture"], 2.8, places=5)
        self.assertIsNone(result["capture"]["iso"])
        self.assertIsNone(result["capture"]["shutter_seconds"])

    def test_explicit_zero_baseline_is_not_missing(self):
        # Append a replacement IFD plus a BaselineExposure SRATIONAL 0/1 to a
        # temporary synthetic copy; existing offsets and source pixels stay intact.
        original = self.fixture("linear-uncompressed.dng").read_bytes()
        self.assertEqual(original[:4], b"II\x2a\0")
        offset = struct.unpack_from("<I", original, 4)[0]
        count = struct.unpack_from("<H", original, offset)[0]
        entries = [original[offset + 2 + index * 12:offset + 14 + index * 12] for index in range(count)]
        self.assertNotIn(50730, [struct.unpack_from("<H", entry)[0] for entry in entries])
        entries.append(struct.pack("<HHII", 50730, 10, 1, len(original)))
        entries.sort(key=lambda entry: struct.unpack_from("<H", entry)[0])
        payload = bytearray(original + struct.pack("<ii", 0, 1))
        struct.pack_into("<I", payload, 4, len(payload))
        payload.extend(struct.pack("<H", len(entries)) + b"".join(entries) + b"\0" * 4)
        path = self.root / "zero-baseline.dng"
        path.write_bytes(payload)
        result = self.envelope(self.run_cli("--info", path, "--json"))["result"]
        self.assert_metadata(result, path)
        self.assertEqual(result["capture"]["baseline_exposure_ev"], 0)

    def test_real_raw_metadata_and_flag_order(self):
        if not RAW_SAMPLES:
            self.skipTest("real RAW fixture not provided")
        for raw_path in RAW_SAMPLES:
            baseline = None
            for arguments in (("--info", raw_path, "--json"), ("--json", "--info", raw_path), ("--info", raw_path)):
                with self.subTest(raw=raw_path.name, arguments=arguments):
                    result = self.envelope(self.run_cli(*arguments))["result"]
                    self.assert_metadata(result, raw_path)
                    self.assertTrue(result["camera"]["make"])
                    self.assertTrue(result["camera"]["model"])
                    if baseline is None:
                        baseline = result
                    self.assertEqual(result, baseline)
            if raw_path.name == "DJI_20250602164503_0444_D.DNG":
                self.assertIsNotNone(baseline["capture"]["baseline_exposure_ev"], "known DJI BaselineExposure tag must be reported")
                self.assertAlmostEqual(baseline["capture"]["baseline_exposure_ev"], .35, places=5)
                print(
                    f"Verified DJI BaselineExposure: {raw_path.name} baseline_exposure_ev={baseline['capture']['baseline_exposure_ev']}",
                    flush=True,
                )

    def test_relative_unicode_input_path(self):
        source = self.fixture("linear-uncompressed.dng")
        path = self.root / "样片 🌅.dng"
        shutil.copyfile(source, path)
        result = self.envelope(self.run_cli("--info", path.name, "--json", cwd=self.root))["result"]
        self.assert_metadata(result, path)
        self.assertIn(path.name, result["input_path"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--raw", type=str)
    parser.add_argument("--default-raw", type=str)
    parser.add_argument("--fixtures", type=pathlib.Path)
    arguments, remaining = parser.parse_known_args()
    CLI = arguments.cli.resolve()
    RAW_SAMPLES = []
    if arguments.raw:
        explicit_raw = pathlib.Path(arguments.raw)
        if not explicit_raw.is_file():
            print(f"FAIL raw_info_cli: --raw does not exist: {arguments.raw}", file=sys.stderr)
            sys.exit(1)
        RAW_SAMPLES.append(explicit_raw.resolve())
        if arguments.default_raw:
            default_raw = pathlib.Path(arguments.default_raw)
            if default_raw.is_file() and default_raw.resolve() not in RAW_SAMPLES:
                RAW_SAMPLES.append(default_raw.resolve())
    else:
        env_raw = os.environ.get("RAWLAB_TEST_RAW", "")
        if env_raw and not pathlib.Path(env_raw).is_file():
            print(f"FAIL raw_info_cli: RAWLAB_TEST_RAW does not exist: {env_raw}", file=sys.stderr)
            sys.exit(1)
        if arguments.default_raw and pathlib.Path(arguments.default_raw).is_file():
            RAW_SAMPLES.append(pathlib.Path(arguments.default_raw).resolve())
        if env_raw:
            env_path = pathlib.Path(env_raw).resolve()
            if env_path not in RAW_SAMPLES:
                RAW_SAMPLES.append(env_path)
    FIXTURES = arguments.fixtures.resolve() if arguments.fixtures else None
    program = unittest.main(argv=[__file__, *remaining], exit=False)
    if not program.result.wasSuccessful():
        sys.exit(1)
    if not RAW_SAMPLES:
        print("SKIP raw_info_cli: default RAW sample not present and RAWLAB_TEST_RAW not set")
        sys.exit(77)
