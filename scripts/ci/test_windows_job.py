"""Execute the Windows job's environment setup without installing tools or touching E:."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
PWSH = os.environ.get("RAWLAB_TEST_PWSH") or shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell is needed to execute the Windows job setup")
class WindowsJobEnvironmentTests(unittest.TestCase):
    def configure(self, environment, directory):
        workflow = yaml.load((ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader)
        steps = workflow["jobs"]["windows"]["steps"]
        configure = [step for step in steps if step.get("id") == "windows-env"]
        self.assertEqual(len(configure), 1, "Configure both Windows runner types before installing tools")
        output = directory / "github-env"
        output.write_text("EXISTING=kept\n")
        result = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command", configure[0]["run"]],
            env={**os.environ, "CI_RUNNER_ENVIRONMENT": environment,
                 "RUNNER_TEMP": str(directory), "GITHUB_ENV": str(output)},
            capture_output=True, text=True)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return result, values

    def test_hosted_jobs_keep_paths_under_runner_temp_and_cap_build_processes(self):
        with tempfile.TemporaryDirectory(prefix="rawlab windows ") as directory:
            result, values = self.configure("github-hosted", Path(directory))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(values, {
                "EXISTING": "kept", "DOTNET_INSTALL_DIR": directory + "\\rawlab-ci\\dotnet",
                "RAWLAB_LENS_SOURCE_CACHE": directory + "\\rawlab-ci\\cache\\lens-sources",
                "RAWLAB_AI_SHARED_CACHE": directory + "\\rawlab-ci\\cache",
                "JOBS": "4", "CMAKE_BUILD_PARALLEL_LEVEL": "4", "CL_MPCount": "4",
            })

    def test_dedicated_jobs_preserve_the_data_volume_and_existing_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            result, values = self.configure("self-hosted", Path(directory))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(values, {
                "EXISTING": "kept", "DOTNET_INSTALL_DIR": "E:\\RawLabCI\\dotnet",
                "RAWLAB_LENS_SOURCE_CACHE": "E:\\RawLabCI\\cache\\lens-sources",
                "RAWLAB_AI_SHARED_CACHE": "E:\\RawLabCI\\cache",
                "JOBS": "16", "CMAKE_BUILD_PARALLEL_LEVEL": "16", "CL_MPCount": "24",
            })

    def test_unknown_runner_environment_fails_without_changing_the_job(self):
        with tempfile.TemporaryDirectory() as directory:
            result, values = self.configure("unknown", Path(directory))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unknown Windows runner environment.", result.stderr)
            self.assertEqual(values, {"EXISTING": "kept"})


if __name__ == "__main__":
    unittest.main()
