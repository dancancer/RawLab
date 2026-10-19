"""Differential checks against the existing preparation tool; never shipped in the app."""

import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from lutools.lutprep.dcp import D65, PROPHOTO_TO_XYZ, DCPProfile
from lutools.lutprep.native import compile_dcp, read_native
from lutools.tests.test_lutprep_dcp import identity_table, rationals, write_dcp

if len(sys.argv) == 3 and sys.argv[1] == "--fixtures":
    destination = Path(sys.argv[2])
    destination.mkdir(parents=True, exist_ok=True)
    write_dcp(destination / "Supported camera look.dcp", extra={51110: (4, [1])})
    write_dcp(destination / "Missing tone.dcp", extra={51110: (4, [1])}, omit=(50940,))
    sys.exit(0)

COMPILER = sys.argv.pop(1)


class NativeDCPCompilerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rawlab-dcp-parity-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_compiler(self, source, output, ok=True):
        result = subprocess.run([COMPILER, str(source), str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if ok else 2, result.stderr)
        return result

    def compare(self, **options):
        source, output, reference = [self.root / name for name in ("源外观.dcp", "native.rlook", "python.rlook")]
        options["extra"] = {51110: (4, [1]), **options.get("extra", {})}
        write_dcp(source, **options)
        original = source.read_bytes()
        self.run_compiler(source, output)
        compile_dcp(source, reference, force=True)
        actual, expected = read_native(output), read_native(reference)
        self.assert_same_stages(actual, expected)
        self.assertEqual(source.read_bytes(), original)

    def assert_same_stages(self, actual, expected):
        for field in ("input_matrix", "output_matrix", "exposure", "tone", "encoding", "calibration_encoding"):
            np.testing.assert_allclose(actual[field], expected[field], atol=2e-12, rtol=1e-12, err_msg=field)
        for field in ("table", "calibration_table"):
            if expected[field] is None:
                self.assertIsNone(actual[field])
            else:
                np.testing.assert_array_equal(actual[field], expected[field])
        for field in ("source", "mode", "format_version", "rgb_cube_baked", "input", "output", "dcp"):
            self.assertEqual(actual["metadata"][field], expected["metadata"][field], field)

    def test_supported_stages_match_python(self):
        rng = np.random.default_rng(2828)
        for endian in ("<", ">"):
            for encoding, values in ((0, 1), (0, 3), (1, 3)):
                for calibration, no_look in ((False, False), (True, False), (True, True)):
                    with self.subTest(endian=endian, encoding=encoding, calibration=calibration, no_look=no_look):
                        table = identity_table(5, 4, values)
                        table[..., 0] = rng.uniform(-180, 180, table.shape[:-1])
                        table[..., 1:] = rng.uniform(0.1, 1.5, table[..., 1:].shape)
                        extra = {51109: (10, [(-3, 4)])}
                        if calibration:
                            hsm = table[:, ::-1].copy()
                            extra.update({50937: (4, [5, 4, values]), 50938: (11, hsm.ravel().tolist()), 51107: (4, [encoding])})
                        self.compare(endian=endian, table=table, encoding=encoding,
                                     curve=[0, 0, .08, .1, .4, .3, .6, .9, 1, 1], extra=extra,
                                     omit=(50981, 50982, 51108) if no_look else ())

    def test_d65_slot_and_normalization(self):
        for slot in (1, 2, 3):
            with self.subTest(slot=slot):
                illuminant, color, forward = {1: (50778, 50721, 50964), 2: (50779, 50722, 50965), 3: (52529, 52531, 52532)}[slot]
                extra = {illuminant: (3, [21]), color: (10, rationals(np.eye(3) * 7)),
                         forward: (10, rationals(np.diag([2, 3, 4]) @ PROPHOTO_TO_XYZ))}
                self.compare(extra=extra, omit=() if slot == 2 else (50779, 50722, 50965))

    def test_dual_hsm_selection_and_omitted_saturation(self):
        a, b = identity_table(4, 3, 2), identity_table(4, 3, 2)
        a[..., 0], b[..., 0] = 25, -35
        for slot in (1, 2):
            extra = {50937: (4, [4, 3, 2]), 50938: (11, a[:, :, 1:].ravel().tolist()),
                     50939: (11, b[:, :, 1:].ravel().tolist())}
            if slot == 1:
                extra.update({50778: (3, [21]), 50721: (10, rationals(np.eye(3))),
                              50964: (10, rationals(PROPHOTO_TO_XYZ)), 50779: (3, [17])})
            self.compare(extra=extra)

    def test_nondiagonal_calibration_matrices_match_python(self):
        rng = np.random.default_rng(9137)
        for _ in range(12):
            color = np.eye(3) + rng.uniform(-.04, .15, (3, 3))
            forward = (np.eye(3) + rng.uniform(-.02, .1, (3, 3))) @ PROPHOTO_TO_XYZ
            with self.subTest(color=color.tolist()):
                self.compare(extra={50722: (10, rationals(color)), 50965: (10, rationals(forward))})

    def test_tone_endpoints_and_two_dimensional_tables(self):
        self.compare(table=identity_table(4, 3, 1), curve=[.1, .2, .9, .8], extra={50981: (4, [4, 3])})
        self.compare(omit=(50981, 50982, 51108))

    def test_rejection_does_not_create_or_replace_output(self):
        source, output = self.root / "bad.dcp", self.root / "existing.rlook"
        cases = [
            {"omit": (50940,)}, {"omit": (51110,)}, {"omit": (50965,)},
            {"extra": {52537: (11, [1])}}, {"extra": {52539: (4, [1])}},
            {"extra": {50981: (4, [4294967295, 4294967295, 4294967295])}},
            {"extra": {50940: (11, [0, 0, 0, 1])}},
            {"extra": {50722: (10, rationals(np.zeros((3, 3))))}},
            {"extra": {51109: (10, [(17, 1)])}},
            {"extra": {50982: (11, [float("nan")] * 24)}},
        ]
        for options in cases:
            options["extra"] = {51110: (4, [1]), **options.get("extra", {})}
            write_dcp(source, **options)
            output.write_bytes(b"keep")
            result = self.run_compiler(source, output, ok=False)
            self.assertTrue(result.stderr.strip())
            self.assertEqual(output.read_bytes(), b"keep")
        valid = write_dcp(source, extra={51110: (4, [1])}).read_bytes()
        for change in (lambda b: struct.pack_into("<I", b, 4, 0xffffffff),
                       lambda b: struct.pack_into("<I", b, 18, 0xffffffff),
                       lambda b: struct.pack_into("<H", b, 8, 65535)):
            data = bytearray(valid)
            change(data)
            source.write_bytes(data)
            self.run_compiler(source, output, ok=False)
        with source.open("wb") as stream:
            stream.truncate(128 * 1024 * 1024 + 1)
        self.run_compiler(source, output, ok=False)

    @unittest.skipUnless(os.environ.get("RAWLAB_TEST_CANON_DCP"), "Optional privately owned Canon DCP")
    def test_private_profile_when_strict_policy_is_supported(self):
        source = Path(os.environ["RAWLAB_TEST_CANON_DCP"])
        profile = DCPProfile.read(source)
        if profile.black_render_policy != "none-profile":
            self.skipTest("Private fixture requires explicit black policy, not automatic native import")
        output = self.root / "real.rlook"
        self.run_compiler(source, output)
        reference = self.root / "real-reference.rlook"
        compile_dcp(source, reference)
        self.assert_same_stages(read_native(output), read_native(reference))


if __name__ == "__main__":
    unittest.main(verbosity=2)
