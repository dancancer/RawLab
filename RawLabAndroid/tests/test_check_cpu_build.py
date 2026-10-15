import importlib.util
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("check_cpu_build", Path(__file__).with_name("check-cpu-build.py"))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
REPO = Path(__file__).resolve().parents[2]


class CpuBuildPolicyTest(unittest.TestCase):
    def entries(self):
        result = []
        sources = (
            ("/build/core/wavelib/wavelib.c", "wavelib"),
            (str(REPO / "lutools/src/core/wavelet_denoise.cpp"), "sony2fuji_core"),
            ("/build/_deps/rawlab_opencv-src/modules/core/src/matrix.cpp", "opencv_core"),
            ("/build/_deps/rawlab_opencv-src/modules/imgproc/src/box_filter.dispatch.cpp", "opencv_imgproc"),
            ("/build/_deps/rawlab_opencv-src/modules/imgproc/src/filter.dispatch.cpp", "opencv_imgproc"),
            ("/build/_deps/rawlab_wavelib-src/src/wtmath.c", "wavelib"),
        )
        for source, target in sources:
            result.append({"directory": "/build", "file": source,
                           "arguments": ["clang", "-g", "-O0", "-O3", "-o",
                                         f"CMakeFiles/{target}.dir/{Path(source).name}.o"]})
        return result

    def test_last_optimization_wins(self):
        self.assertEqual("-O3", policy.effective_optimization(["-O0", "-O3"]))
        self.assertEqual("-O0", policy.effective_optimization(["-O3", "-O0"]))
        self.assertEqual("-O0", policy.effective_optimization(["-g"]))
        self.assertEqual("-O0", policy.effective_optimization(["-DNAME=-O3"]))
        for option in ("-O", "-O1", "-O2", "-Og", "-Os", "-Oz", "-Ofast"):
            self.assertEqual(option, policy.effective_optimization(["-O3", option]))

    def test_arguments_and_quoted_command(self):
        entries = self.entries()
        self.assertFalse(policy.validate(entries)[1])
        entry = entries[0]
        entry["command"] = "clang '-I/path with space' -O0 -O3 -o 'CMakeFiles/wavelib.dir/source.o'"
        del entry["arguments"]
        self.assertFalse(policy.validate(entries)[1])

    def test_missing_and_duplicate_sources_fail(self):
        entries = self.entries()
        self.assertTrue(policy.validate(entries[1:])[1])
        self.assertTrue(policy.validate(entries + [entries[0]])[1])
        self.assertTrue(policy.validate([])[1])

    def test_late_o0_and_fast_math_fail(self):
        for flag in ("-O0", "-Ofast", "-ffast-math", "-funsafe-math-optimizations", "@hidden-flags"):
            with self.subTest(flag=flag):
                entries = self.entries()
                entries[0]["arguments"].append(flag)
                self.assertTrue(policy.validate(entries)[1])

    def test_every_target_object_is_checked(self):
        entries = self.entries()
        entries.append({"directory": "/build", "file": "/fixture/extra.cpp", "arguments": ["clang", "-O0", "-o",
                        "CMakeFiles/opencv_core.dir/extra.o"]})
        self.assertTrue(policy.validate(entries)[1])

    def test_required_object_cannot_hide_under_unknown_target(self):
        for output in ("CMakeFiles/unknown.dir/source.o", "source.o"):
            with self.subTest(output=output):
                entries = self.entries()
                entries[0]["arguments"][-1] = output
                self.assertTrue(policy.validate(entries)[1])

    def test_individual_lossy_math_flags_fail(self):
        flags = ("-ffinite-math-only", "-fno-honor-nans", "-fno-honor-infinities",
                 "-fno-signed-zeros", "-fapprox-func", "-fno-trapping-math",
                 "-menable-no-nans", "-menable-no-infs", "-mreassociate")
        for flag in flags:
            for command_string in (False, True):
                with self.subTest(flag=flag, command_string=command_string):
                    entries = self.entries()
                    entries[0]["arguments"].append(flag)
                    if command_string:
                        entries[0]["command"] = " ".join(entries[0].pop("arguments"))
                    self.assertTrue(policy.validate(entries)[1])

    def test_lossy_or_unknown_fp_modes_fail(self):
        flags = ("-ffp-model=fast", "-ffp-model=aggressive", "-ffp-model=unknown",
                 "-ffp-contract=fast", "-ffp-contract=fast-honor-pragmas",
                 "-ffp-contract=unknown", "-fdenormal-fp-math=preserve-sign",
                 "-fdenormal-fp-math=ieee,positive-zero",
                 "-fdenormal-fp-math-f32=positive-zero,ieee", "-mrecip=all")
        for flag in flags:
            with self.subTest(flag=flag):
                entries = self.entries()
                entries[0]["arguments"].append(flag)
                self.assertTrue(policy.validate(entries)[1])

    def test_safe_fp_modes_pass(self):
        for flag in ("-ffp-model=precise", "-ffp-model=strict", "-ffp-contract=on",
                     "-ffp-contract=off", "-fdenormal-fp-math=ieee",
                     "-fdenormal-fp-math-f32=ieee,ieee", "-mrecip=none",
                     "-fhonor-nans", "-fhonor-infinities", "-fsigned-zeros"):
            with self.subTest(flag=flag):
                entries = self.entries()
                entries[0]["arguments"].append(flag)
                self.assertFalse(policy.validate(entries)[1])

    def test_opaque_compiler_options_fail_closed(self):
        for flags in (("-Xclang", "-menable-no-nans"), ("-Xclang=-menable-no-infs",),
                      ("-mllvm", "-enable-unsafe-fp-math"),
                      ("-mllvm=-enable-unsafe-fp-math",), ("--config=hidden.cfg",)):
            with self.subTest(flags=flags):
                entries = self.entries()
                entries[0]["arguments"].extend(flags)
                self.assertTrue(policy.validate(entries)[1])

    def test_unsafe_option_is_not_hidden_by_a_later_safe_override(self):
        entries = self.entries()
        entries[0]["arguments"].extend(["-ffinite-math-only", "-fno-finite-math-only"])
        self.assertTrue(policy.validate(entries)[1])

    def test_required_source_cannot_be_replaced_by_same_suffix(self):
        original = self.entries()
        self.assertFalse(policy.validate(original)[1])
        for index in range(len(original)):
            with self.subTest(source=original[index]["file"]):
                entries = copy.deepcopy(original)
                entries[index]["file"] = "/shadow" + entries[index]["file"]
                errors = policy.validate(entries)[1]
                self.assertEqual(1, len(errors))
                self.assertIn("Expected exactly one", errors[0])

    def test_required_sources_accept_relative_paths(self):
        entries = self.entries()
        for entry in entries:
            entry["file"] = os.path.relpath(entry["file"], entry["directory"])
        self.assertFalse(policy.validate(entries)[1])

    def compare_cli(self, before, after):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory, name) for name in ("before.json", "after.json")]
            for path, entries in zip(paths, (before, after)):
                path.write_text(json.dumps(entries))
            return subprocess.run([sys.executable, "-B", str(Path(policy.__file__)),
                                   "--compare", *map(str, paths)], capture_output=True, text=True)

    def comparison_entries(self):
        entries = self.entries()
        for entry in entries:
            entry["directory"] = "/build"
        for name in ("first", "second"):
            entries.append({"directory": "/build", "file": "/fixture/extra.cpp",
                            "arguments": ["clang", "-O0", "-o",
                                          f"CMakeFiles/opencv_core.dir/{name}.o"]})
        return entries

    def test_compare_preserves_distinct_outputs_for_same_source(self):
        before = self.comparison_entries()
        after = copy.deepcopy(before)
        for entry in after[-2:]:
            entry["arguments"].append("-O3")
        after.append({"directory": "/build", "file": str(REPO / "lutools/tests/wavelet_denoise_tests.cpp"),
                      "arguments": ["clang", "-o", "CMakeFiles/wavelet_denoise_tests.dir/test.o"]})
        result = self.compare_cli(before, after)
        self.assertEqual(0, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(8, report["before_records"])
        self.assertEqual(7, report["before_sources"])
        self.assertEqual(9, report["after_records"])
        self.assertEqual(8, report["after_sources"])
        self.assertEqual(2, report["changed_objects"])
        self.assertEqual({"opencv_core": 2}, report["changed_targets"])
        self.assertEqual(1, len(report["added_objects"]))
        self.assertFalse(report["removed_objects"])
        self.assertFalse(report["errors"])

    def test_compare_rejects_duplicate_or_missing_object_identity(self):
        entries = self.comparison_entries()
        for bad in (entries + [copy.deepcopy(entries[-1])],
                    entries + [{"directory": "/build", "file": "/fixture/unknown.cpp", "arguments": ["clang"]}]):
            with self.subTest(bad=bad[-1]):
                result = self.compare_cli(bad, entries)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("object", result.stderr.lower())

    def test_compare_detects_change_to_first_repeated_source_object(self):
        before = self.comparison_entries()
        for entry in before[-2:]:
            entry["arguments"].append("-O3")
        after = copy.deepcopy(before)
        after[-2]["arguments"].append("-DOBJECT_GUARD_PROBE=1")
        self.assertFalse(policy.validate(after)[1])
        result = self.compare_cli(before, after)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(1, report["changed_objects"])
        self.assertEqual(1, len(report["errors"]))
        self.assertIn("Unexpected compile change", report["errors"][0])

    def test_compare_rejects_reordered_options_and_removed_objects(self):
        before = self.comparison_entries()
        for entry in before[-2:]:
            entry["arguments"].append("-O3")
        for mutation in ("reorder", "remove"):
            with self.subTest(mutation=mutation):
                after = copy.deepcopy(before)
                if mutation == "reorder":
                    after[-2]["arguments"] = ["clang", "-O0", "-O3", "-o", "CMakeFiles/opencv_core.dir/first.o"]
                else:
                    after.pop()
                self.assertFalse(policy.validate(after)[1])
                result = self.compare_cli(before, after)
                self.assertEqual(1, result.returncode, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(int(mutation == "reorder"), report["changed_objects"])
                self.assertEqual(int(mutation == "remove"), len(report["removed_objects"]))
                self.assertEqual(1, len(report["errors"]))
                expected = "Unexpected compile change" if mutation == "reorder" else "Removed compile object"
                self.assertIn(expected, report["errors"][0])

    def test_compare_normalizes_relative_sources_and_explicit_outputs(self):
        before = self.comparison_entries()
        after = copy.deepcopy(before)
        for entry in after[-2:]:
            entry["file"] = "../fixture/extra.cpp"
            entry["output"] = "/build/./" + entry["arguments"][-1]
            entry["arguments"].append("-O3")
        result = self.compare_cli(before, after)
        self.assertEqual(0, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(2, report["changed_objects"])
        self.assertFalse(report["added_objects"])
        self.assertFalse(report["removed_objects"])

    def test_compare_rejects_conflicting_output_metadata(self):
        entries = self.comparison_entries()
        entries[-1]["output"] = "CMakeFiles/opencv_core.dir/different.o"
        result = self.compare_cli(entries, entries)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Conflicting object output", result.stderr)

    def test_compare_reports_unknown_target_changes(self):
        before = self.entries()
        for entry in before:
            entry["directory"] = "/build"
        before.append({"directory": "/build", "file": "/fixture/unknown.cpp",
                       "arguments": ["clang", "-o", "unknown.o"]})
        after = copy.deepcopy(before)
        after[0]["arguments"].append("-O3")
        after[-1]["arguments"].append("-O3")
        result = self.compare_cli(before, after)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual({"<unknown>": 1, "wavelib": 1}, report["changed_targets"])
        self.assertTrue(report["errors"])

    def test_compare_rejects_unexpected_added_object(self):
        before = self.entries()
        for entry in before:
            entry["directory"] = "/build"
        after = copy.deepcopy(before)
        after.append({"directory": "/build", "file": "/fixture/unexpected.cpp",
                      "arguments": ["clang", "-o", "CMakeFiles/unknown.dir/new.o"]})
        result = self.compare_cli(before, after)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(1, len(report["added_objects"]))
        self.assertTrue(report["errors"])

    def test_compare_rejects_shadow_numerical_test_source(self):
        before = self.entries()
        after = copy.deepcopy(before)
        after.append({"directory": "/build",
                      "file": "/shadow" + str(REPO / "lutools/tests/wavelet_denoise_tests.cpp"),
                      "arguments": ["clang", "-o", "CMakeFiles/wavelet_denoise_tests.dir/test.o"]})
        self.assertFalse(policy.validate(after)[1])
        result = self.compare_cli(before, after)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(1, len(report["errors"]))
        self.assertIn("Unexpected added object", report["errors"][0])

    def test_compare_rejects_multiple_numerical_test_objects(self):
        before = self.entries()
        after = copy.deepcopy(before)
        for name in ("first", "second"):
            after.append({"directory": "/build", "file": str(REPO / "lutools/tests/wavelet_denoise_tests.cpp"),
                          "arguments": ["clang", "-o", f"CMakeFiles/wavelet_denoise_tests.dir/{name}.o"]})
        self.assertFalse(policy.validate(after)[1])
        result = self.compare_cli(before, after)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(2, len(report["added_objects"]))
        self.assertEqual(1, len(report["errors"]))
        self.assertIn("Multiple numerical-test objects", report["errors"][0])

    def test_unrelated_target_forwarding_does_not_fail_cpu_policy(self):
        entries = self.entries()
        entries.append({"directory": "/build", "file": "/fixture/unrelated.cpp", "arguments": ["clang", "-Xclang",
                        "-mrelax-all", "-o", "CMakeFiles/jxl.dir/unrelated.o"]})
        self.assertFalse(policy.validate(entries)[1])


if __name__ == "__main__":
    unittest.main()
