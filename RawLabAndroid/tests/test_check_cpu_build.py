import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("check_cpu_build", Path(__file__).with_name("check-cpu-build.py"))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class CpuBuildPolicyTest(unittest.TestCase):
    def entries(self):
        result = []
        for suffix in sorted(policy.REQUIRED):
            target = ("sony2fuji_core" if "wavelet_denoise" in suffix else
                      "wavelib" if suffix.endswith(("wavelib.c", "wtmath.c")) else
                      "opencv_core" if "/core/src/" in suffix else "opencv_imgproc")
            result.append({"file": "/fixture" + suffix,
                           "arguments": ["clang", "-g", "-O0", "-O3", "-o",
                                         f"CMakeFiles/{target}.dir/source.o"]})
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
        entries.append({"file": "/fixture/extra.cpp", "arguments": ["clang", "-O0", "-o",
                        "CMakeFiles/opencv_core.dir/extra.o"]})
        self.assertTrue(policy.validate(entries)[1])

    def test_required_object_cannot_hide_under_unknown_target(self):
        for output in ("CMakeFiles/unknown.dir/source.o", "source.o"):
            with self.subTest(output=output):
                entries = self.entries()
                entries[0]["arguments"][-1] = output
                self.assertTrue(policy.validate(entries)[1])


if __name__ == "__main__":
    unittest.main()
