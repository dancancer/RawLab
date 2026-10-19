"""Exercise archive recovery without installing anything on the test host."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("provision-android-runner.sh")


class WindowsRunnerConfigurationTests(unittest.TestCase):
    def test_windows_path_is_in_the_environment_file_loaded_by_runner_listener(self):
        text = SCRIPT.with_name("provision-windows-runner.ps1").read_text()
        self.assertIn('"Path=$path"', text)
        self.assertNotIn('WriteAllText("$runner\\.path"', text)


@unittest.skipUnless(shutil.which("bash") and shutil.which("curl") and shutil.which("sha256sum"),
                     "Requires bash, curl and sha256sum")
class RunnerArchiveTests(unittest.TestCase):
    def download(self, source, checksum, destination):
        return subprocess.run([
            "bash", "-c", 'source "$1"; download_verified "$2" "$3" "$4"',
            "bash", str(SCRIPT), source.as_uri(), checksum, str(destination),
        ], capture_output=True, text=True)

    def test_partial_download_and_corrupt_cache_are_replaced(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-runner-") as temporary:
            root = Path(temporary)
            source, destination = root / "source.zip", root / "cache.zip"
            source.write_bytes(b"verified toolchain archive")
            checksum = hashlib.sha256(source.read_bytes()).hexdigest()
            destination.write_bytes(b"interrupted old download")
            destination.with_suffix(".zip.part").write_bytes(b"partial")
            result = self.download(source, checksum, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertFalse(destination.with_suffix(".zip.part").exists())

    def test_valid_cache_does_not_need_the_download_source(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-runner-") as temporary:
            root = Path(temporary)
            destination = root / "cache.zip"
            destination.write_bytes(b"already verified")
            destination.with_suffix(".zip.part").write_bytes(b"abandoned partial")
            checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
            result = self.download(root / "missing.zip", checksum, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(destination.with_suffix(".zip.part").exists())

    def test_checksum_failure_never_publishes_a_partial_archive(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-runner-") as temporary:
            root = Path(temporary)
            source, destination = root / "source.zip", root / "cache.zip"
            source.write_bytes(b"wrong archive")
            result = self.download(source, "0" * 64, destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum", result.stderr)
            self.assertFalse(destination.exists())
            self.assertFalse(destination.with_suffix(".zip.part").exists())
