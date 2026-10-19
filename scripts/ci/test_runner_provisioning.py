"""Exercise archive recovery without installing anything on the test host."""
import hashlib
import os
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


class MacRunnerConfigurationTests(unittest.TestCase):
    def test_ios_runtime_is_checked_before_runner_files_are_created(self):
        text = SCRIPT.with_name('provision-macos-runner.sh').read_text()
        command = 'xcrun simctl list runtimes available -j'
        self.assertIn(command, text)
        self.assertIn('runtime.get("platform") == "iOS" and runtime.get("isAvailable")', text)
        self.assertLess(text.index(command), text.index('mkdir -p'))

    def test_personal_account_requires_explicit_opt_in_and_never_root(self):
        script = SCRIPT.with_name('provision-macos-runner.sh')
        with tempfile.TemporaryDirectory(prefix='rawlab-mac-personal-runner-') as temporary:
            root = Path(temporary)
            home, external, tools = (root / name for name in ('home', 'external', 'tools'))
            for directory in (home, external, tools):
                directory.mkdir()
            for name, cases in {
                'uname': '-s) echo Darwin;; -m) echo arm64;;',
                'id': '-un) echo developer;; -Gn) echo "staff admin";; -u) echo "${TEST_UID:-501}";;',
            }.items():
                tool = tools / name
                tool.write_text('#!/bin/sh\ncase "$1" in ' + cases + ' esac\n')
                tool.chmod(0o755)
            command = ['bash', str(script), str(external), str(root / 'Xcode.app'), str(root / 'runner.tar.gz')]
            environment = {**os.environ, 'HOME': str(home), 'PATH': str(tools) + os.pathsep + os.defpath}
            denied = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertNotEqual(denied.returncode, 0)
            self.assertIn('Use the non-administrator rawlab-ci account', denied.stderr)
            allowed = subprocess.run(command + ['--allow-current-user'], env=environment,
                                     capture_output=True, text=True)
            self.assertIn('Keep runner startup files and Python inside', allowed.stderr)
            root_user = subprocess.run(command + ['--allow-current-user'],
                                       env={**environment, 'TEST_UID': '0'}, capture_output=True, text=True)
            self.assertNotEqual(root_user.returncode, 0)
            self.assertNotIn('Keep runner startup files', root_user.stderr)

    def test_listener_environment_keeps_python_after_config_overwrites_dot_path(self):
        text = SCRIPT.with_name('provision-macos-runner.sh').read_text()
        self.assertIn('"PATH=$root/venv/bin:$PATH"', text)

    def test_provisioning_refuses_the_developer_or_non_mac_account(self):
        script = SCRIPT.with_name('provision-macos-runner.sh')
        result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Use the non-administrator rawlab-ci account on an Apple Silicon Mac.', result.stderr)

    def test_runner_startup_files_must_stay_inside_the_ci_home(self):
        script = SCRIPT.with_name('provision-macos-runner.sh')
        with tempfile.TemporaryDirectory(prefix='rawlab-mac-runner-') as temporary:
            root = Path(temporary)
            home, external, tools = (root / name for name in ('home', 'external', 'tools'))
            for directory in (home, external, tools):
                directory.mkdir()
            for name, cases in {
                'uname': '-s) echo Darwin;; -m) echo arm64;;',
                'id': '-un) echo rawlab-ci;; -Gn) echo staff;;',
            }.items():
                tool = tools / name
                tool.write_text('#!/bin/sh\ncase "$1" in ' + cases + ' esac\n')
                tool.chmod(0o755)
            result = subprocess.run([
                'bash', str(script), str(external), str(root / 'Xcode.app'), str(root / 'runner.tar.gz'),
            ], env={**os.environ, 'HOME': str(home), 'PATH': str(tools) + os.pathsep + os.defpath},
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Keep runner startup files and Python inside the CI user home.', result.stderr)


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
