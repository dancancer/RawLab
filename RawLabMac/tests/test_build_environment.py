"""Deployment targets must not reuse higher-minimum dependency binaries."""
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildEnvironmentTests(unittest.TestCase):
    def environment(self, **overrides):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("RAWLAB_") and key != "MACOSX_DEPLOYMENT_TARGET"}
        env.update(overrides)
        command = ('ROOT="$1"; source "$ROOT/RawLabMac/build-env.sh"; '
                   'printf "%s\\0" "$MACOSX_DEPLOYMENT_TARGET" "$ARCH" '
                   '"$RAWLAB_DEPENDENCY_PREFIX" "$RAWLAB_LENS_PREFIX" "$RAWLAB_SOURCE_CACHE" '
                   '"${PKG_CONFIG_PATH:-}" "${PKG_CONFIG_LIBDIR:-}"')
        result = subprocess.run(["/bin/bash", "-euc", command, "test", str(ROOT)],
                                env=env, capture_output=True, text=True)
        return result

    def test_default_target_and_output_paths(self):
        result = self.environment(RAWLAB_ARCH="arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = result.stdout.split("\0")
        self.assertEqual(values[:4], ["14.0", "arm64",
                         str(ROOT / "build/macos-deps/14.0/arm64/install"),
                         str(ROOT / "build/lensfun/14.0/arm64/install")])
        common = subprocess.check_output(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                         cwd=ROOT, text=True).strip()
        self.assertEqual(Path(values[4]).resolve(),
                         (Path(common).parent / ".cache/shared/macos-sources").resolve())

    def test_architecture_and_target_outputs_are_distinct(self):
        results = [self.environment(RAWLAB_ARCH=arch, MACOSX_DEPLOYMENT_TARGET=target)
                   for arch, target in [("arm64", "14.0"), ("x86_64", "14.0"), ("arm64", "15.0")]]
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        paths = [result.stdout.split("\0")[2:4] for result in results]
        self.assertEqual(len({tuple(path) for path in paths}), 3)
        self.assertEqual(len({result.stdout.split("\0")[4] for result in results}), 1)

    def test_invalid_architecture_or_target_is_rejected(self):
        for overrides in ({"RAWLAB_ARCH": "unknown"}, {"MACOSX_DEPLOYMENT_TARGET": "../26.0"}):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(self.environment(**overrides).returncode, 0)

    def test_pkg_config_cannot_fall_back_to_another_build(self):
        result = self.environment(RAWLAB_ARCH="arm64", PKG_CONFIG_PATH="/foreign/build/lib/pkgconfig")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = result.stdout.split("\0")
        expected = f"{values[3]}/lib/pkgconfig:{values[2]}/lib/pkgconfig"
        self.assertEqual(values[5], expected)
        self.assertEqual(values[6], expected)

    def test_full_source_swift_builds_use_bounded_whole_module_compilation(self):
        for relative in ('RawLabMac/build.sh', 'RawLabMac/tests/mac-straighten-preview.sh'):
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text()
                self.assertIn('-whole-module-optimization', source)
                self.assertIn('-num-threads "${JOBS:-$(sysctl -n hw.ncpu)}"', source)
                self.assertNotIn('-Ounchecked', source)


if __name__ == "__main__":
    unittest.main()
