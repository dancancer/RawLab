"""Run the Rust bootstrap with local substitutes for downloads and Rust itself."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-rust.sh")
INSTALLER = '''#!/bin/bash
set -eu
mkdir -p "$CARGO_HOME/bin"
cat > "$CARGO_HOME/bin/rustup" <<'RUSTUP'
#!/bin/sh
printf '%s\\n' "$*" >> "$RAWLAB_RUST_TEST_LOG"
RUSTUP
chmod +x "$CARGO_HOME/bin/rustup"
'''


class RustBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, root, *, installed=False, corrupt=False):
        tools = root / "bin"
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(f'''#!{sys.executable}
from pathlib import Path
import sys
url = sys.argv[-3]
output = Path(sys.argv[-1])
installer = {INSTALLER!r}
output.write_text(({'0' * 64 if corrupt else hashlib.sha256(INSTALLER.encode()).hexdigest()!r} + '  rustup-init\\n') if url.endswith('.sha256') else installer)
''')
        curl.chmod(0o755)
        if installed:
            rustup = tools / "rustup"
            rustup.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RAWLAB_RUST_TEST_LOG"\n')
            rustup.chmod(0o755)
            curl.write_text('#!/bin/sh\necho "Unexpected download" >&2\nexit 99\n')
        env = {key: value for key, value in os.environ.items()
               if key not in {"CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN"}}
        env.update(PATH=f"{tools}:/usr/bin:/bin", RUNNER_TEMP=str(root / "temp"),
                   GITHUB_PATH=str(root / "github-path"), GITHUB_ENV=str(root / "github-env"),
                   RAWLAB_RUST_TEST_LOG=str(root / "rustup.log"))
        return subprocess.run(["/bin/bash", str(SCRIPT), "aarch64-apple-ios", "x86_64-apple-ios"],
                              env=env, capture_output=True, text=True)

    def test_missing_rustup_is_installed_in_job_directory_and_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cargo = root / "temp/rawlab-x3f-tools/cargo"
            self.assertTrue((cargo / "bin/rustup").is_file())
            self.assertEqual((root / "github-path").read_text().strip(), str(cargo / "bin"))
            exported = (root / "github-env").read_text()
            self.assertIn(f"CARGO_HOME={cargo}\n", exported)
            self.assertIn(f"RUSTUP_HOME={root}/temp/rawlab-x3f-tools/rustup\n", exported)
            self.assertIn("RUSTUP_TOOLCHAIN=1.99.1\n", exported)
            self.assertEqual((root / "rustup.log").read_text().splitlines(), [
                "toolchain install 1.99.1 --profile minimal --component rust-docs",
                "target add --toolchain 1.99.1 aarch64-apple-ios x86_64-apple-ios"])

    def test_bad_installer_checksum_never_executes_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_bootstrap(root, corrupt=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILED", result.stdout + result.stderr)
            self.assertFalse((root / "rustup.log").exists())
            self.assertFalse((root / "temp/rawlab-x3f-tools/cargo/bin/rustup").exists())

    def test_existing_rustup_needs_no_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_bootstrap(root, installed=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / "temp").exists())
            self.assertEqual((root / "github-env").read_text(), "RUSTUP_TOOLCHAIN=1.99.1\n")


if __name__ == "__main__":
    unittest.main()
