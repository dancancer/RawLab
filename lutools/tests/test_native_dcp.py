import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

import numpy as np

from lutools.lutprep.dcp import DCPProfile, SRGB_TO_PROPHOTO
from lutools.lutprep.native import compile_dcp, read_native
from lutools.tests.test_lutprep_dcp import identity_table, write_dcp


class NativeDcpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = write_dcp(self.root / "look.dcp")
        self.destination = self.root / "look.rlook"

    def test_package_preserves_stages_without_rgb_baking(self):
        table = identity_table(4, 3, 3)
        table[1, 1, 2] = [37, .7, 1.2]
        write_dcp(self.source, table=table, encoding=1, curve=[0, 0, .5, .3, 1, 1],
                  extra={51109: (10, [(-1, 2)])})
        original = self.source.read_bytes()
        profile = DCPProfile.read(self.source)
        report = compile_dcp(self.source, self.destination)
        parsed = read_native(self.destination)
        self.assertEqual(report["mode"], "native-dcp")
        self.assertFalse(report["rgb_cube_baked"])
        self.assertEqual(parsed["encoding"], 1)
        np.testing.assert_array_equal(parsed["table"], profile.table)
        np.testing.assert_array_equal(parsed["tone"], profile.curve.samples)
        np.testing.assert_array_equal(parsed["input_matrix"], profile.input_to_prophoto)
        np.testing.assert_array_equal(parsed["output_matrix"], np.linalg.inv(SRGB_TO_PROPHOTO))
        self.assertEqual(parsed["exposure"], 2 ** profile.exposure)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertNotIn(str(self.root), self.destination.read_bytes().decode("latin1"))

    def test_no_clobber_force_and_exposure_choice(self):
        write_dcp(self.source, extra={51109: (10, [(1, 1)])})
        self.destination.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            compile_dcp(self.source, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"existing")
        compile_dcp(self.source, self.destination, force=True, dcp_exposure=False)
        self.assertEqual(read_native(self.destination)["exposure"], 1)
        self.assertEqual(list(self.root.glob(".rawlab-*")), [])

    def test_source_alias_is_never_overwritten(self):
        before = self.source.read_bytes()
        with self.assertRaises(ValueError):
            compile_dcp(self.source, self.source, force=True)
        os.link(self.source, self.destination)
        with self.assertRaises(ValueError):
            compile_dcp(self.source, self.destination, force=True)
        self.assertEqual(self.source.read_bytes(), before)

    def test_rejects_wrong_source_or_destination_type(self):
        with self.assertRaises(ValueError):
            compile_dcp(self.source, self.root / "look.cube")
        source = self.root / "look.cube"
        source.write_bytes(self.source.read_bytes())
        with self.assertRaises(ValueError):
            compile_dcp(source, self.destination)

    def test_header_length_and_nonfinite_corruption_are_rejected(self):
        compile_dcp(self.source, self.destination)
        valid = self.destination.read_bytes()
        corruptions = [valid[:12], valid[:-1], valid + b"trailing",
                       b"BADMAGIC" + valid[8:]]
        for offset, value in [(8, 3), (12, 1), (16, 2), (20, 0), (24, 1),
                              (28, 0), (32, 4096), (36, 65537)]:
            bad = bytearray(valid)
            struct.pack_into("<I", bad, offset, value)
            corruptions.append(bad)
        for offset in [40, 112, 184, 192, 192 + 8 * 12]:
            bad = bytearray(valid)
            struct.pack_into("<f" if offset == 192 else "<d", bad, offset, float("nan"))
            corruptions.append(bad)
        for bad in corruptions:
            with self.subTest(length=len(bad)):
                self.destination.write_bytes(bad)
                with self.assertRaises(ValueError):
                    read_native(self.destination)

    def test_cli_compile_and_inspect_return_json(self):
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "compile-dcp",
                                 str(self.source), str(self.destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "native-dcp")
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "inspect",
                                 str(self.destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["format"], "rlook")

    def test_v2_preserves_hsm_and_absent_look(self):
        hsm = identity_table(4, 3, 2)
        hsm[..., 0] = 15
        write_dcp(self.source, omit=(50981, 50982, 51108), extra={
            50937: (4, [4, 3, 2]), 50938: (11, hsm.ravel().tolist()), 51110: (4, [1])})
        report = compile_dcp(self.source, self.destination)
        self.assertEqual(report["format_version"], 2)
        parsed = read_native(self.destination)
        np.testing.assert_array_equal(parsed["calibration_table"], hsm)
        self.assertIsNone(parsed["table"])
        self.assertEqual(parsed["calibration_encoding"], 0)
        valid = self.destination.read_bytes()
        for offset, value in [(40, 2), (44, 0), (48, 1), (52, 0)]:
            bad = bytearray(valid)
            struct.pack_into("<I", bad, offset, value)
            self.destination.write_bytes(bad)
            with self.assertRaises(ValueError):
                read_native(self.destination)

    def test_cli_requires_explicit_missing_tone_and_black_choices(self):
        write_dcp(self.source, omit=(50940,))
        curve = self.root / "curve.json"
        curve.write_text("[[0,0],[1,1]]")
        command = [sys.executable, "-m", "lutools.lutprep", "compile-dcp", str(self.source),
                   str(self.destination), "--tone-curve", str(curve)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.destination.exists())
        result = subprocess.run(command + ["--no-auto-black"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(read_native(self.destination)["metadata"]["dcp"]["tone_source"], "external")

    def test_invalid_external_curve_is_a_cli_error_not_a_traceback(self):
        write_dcp(self.source, omit=(50940,))
        curve = self.root / "curve.json"
        curve.write_text('{"curve":"not points"}')
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "compile-dcp", str(self.source),
                                 str(self.destination), "--tone-curve", str(curve), "--no-auto-black"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(os.environ.get("RAWLAB_DCP_PROBE"), "Optional built native DCP evaluator")
    def test_native_evaluator_matches_python_on_same_float_inputs(self):
        table = identity_table(5, 4, 3)
        rng = np.random.default_rng(23)
        table[..., 0] = rng.uniform(-180, 180, table.shape[:-1])
        table[..., 1:] = rng.uniform(.2, 1.4, table[..., 1:].shape)
        samples = np.concatenate([rng.uniform(-.2, 2, (4096, 3)),
                                  np.repeat(np.linspace(0, 4, 257)[:, None], 3, axis=1)])
        samples = np.asarray(samples, dtype="<f4")
        input_path, output_path = self.root / "input.f32", self.root / "output.f32"
        samples.tofile(input_path)
        for encoding, values, calibration, no_look in [(0, 1, False, False), (0, 3, False, False),
                (1, 3, False, False), (1, 3, True, False), (0, 1, True, True)]:
            extra = {}
            if calibration:
                hsm = table[:values, ::-1].copy()
                hsm[..., 0] += 47
                extra = {50937: (4, [5, 4, values]), 50938: (11, hsm.ravel().tolist()),
                         51107: (4, [encoding]), 51110: (4, [1]), 51109: (10, [(-1, 2)])}
            write_dcp(self.source, table=table[:values], encoding=encoding,
                      curve=[0, 0, .15, .08, .5, .7, 1, 1], extra=extra,
                      omit=(50981, 50982, 51108) if no_look else ())
            compile_dcp(self.source, self.destination, force=True)
            result = subprocess.run([os.environ["RAWLAB_DCP_PROBE"], "--evaluate",
                                     str(self.destination), str(input_path), str(output_path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = np.fromfile(output_path, dtype="<f4").reshape(-1, 3)
            expected = DCPProfile.read(self.source).evaluate(samples)
            np.testing.assert_allclose(actual, expected, atol=2e-6, rtol=0)


if __name__ == "__main__":
    unittest.main()
