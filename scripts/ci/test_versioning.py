"""Tests for single-source versioning (Shared/version.json and scripts/version/generate.py)."""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts/version/generate.py"
VERSIONED_FILES = (
    "Shared/version.json",
    "RawLab/RawLab/Resources/Info.plist",
    "RawLabMac/Info.plist",
    "RawLabAndroid/app/build.gradle.kts",
    "RawLabWindows/RawLabWindows.csproj",
)

MACOS_CONFIG_SPEC = importlib.util.spec_from_file_location(
    "macos_config", ROOT / "scripts/release/macos_config.py"
)
macos_config = importlib.util.module_from_spec(MACOS_CONFIG_SPEC)
MACOS_CONFIG_SPEC.loader.exec_module(macos_config)


def _copy_versioned_tree(dst: Path) -> None:
    for rel in VERSIONED_FILES:
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)


def _run_generator(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GENERATOR), "--root", str(root), *args],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )


class SingleSourceVersioningTests(unittest.TestCase):
    def test_committed_manifests_match_single_version_source(self) -> None:
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bump_syncs_all_four_platforms_and_passes_check(self) -> None:
        source = json.loads((ROOT / "Shared/version.json").read_text(encoding="utf-8"))
        current_version = source["version"]
        current_build = source["build"]
        next_version = "99.1.2" if current_version != "99.1.2" else "99.1.3"
        next_build = current_build + 7 if current_build + 7 <= 65535 else current_build - 1
        with tempfile.TemporaryDirectory(prefix="rawlab-version-sync-") as tmp:
            root = Path(tmp)
            _copy_versioned_tree(root)
            (root / "Shared/version.json").write_text(
                json.dumps({"version": next_version, "build": next_build}, indent=2) + "\n",
                encoding="utf-8",
            )
            # Before syncing, --check must fail closed without modifying files.
            pre_check = _run_generator(root, "--check")
            self.assertNotEqual(pre_check.returncode, 0)
            self.assertEqual(
                plistlib.loads((root / "RawLabMac/Info.plist").read_bytes())["CFBundleShortVersionString"],
                current_version,
            )

            sync = _run_generator(root)
            self.assertEqual(sync.returncode, 0, sync.stdout + sync.stderr)
            post_check = _run_generator(root, "--check")
            self.assertEqual(post_check.returncode, 0, post_check.stdout + post_check.stderr)

            for rel in ("RawLab/RawLab/Resources/Info.plist", "RawLabMac/Info.plist"):
                info = plistlib.loads((root / rel).read_bytes())
                self.assertEqual(info["CFBundleShortVersionString"], next_version)
                self.assertEqual(info["CFBundleVersion"], str(next_build))

            gradle_text = (root / "RawLabAndroid/app/build.gradle.kts").read_text(encoding="utf-8")
            self.assertIn(f"versionCode = {next_build}", gradle_text)
            self.assertIn(f'versionName = "{next_version}"', gradle_text)

            csproj_root = ET.fromstring((root / "RawLabWindows/RawLabWindows.csproj").read_text(encoding="utf-8"))
            self.assertEqual(csproj_root.findtext("./PropertyGroup/Version"), next_version)
            self.assertEqual(csproj_root.findtext("./PropertyGroup/FileVersion"), f"{next_version}.{next_build}")
            self.assertEqual(
                csproj_root.findtext("./PropertyGroup/InformationalVersion"),
                f"{next_version}+build.{next_build}",
            )

    def test_mutations_in_each_platform_file_fail_check_without_writing(self) -> None:
        source = json.loads((ROOT / "Shared/version.json").read_text(encoding="utf-8"))
        ver = source["version"]
        build = source["build"]
        alt_ver = "0.9.9" if ver != "0.9.9" else "0.9.8"
        alt_build_down = build - 1 if build > 1 else build + 1
        alt_build_up = build + 1 if build < 65535 else build - 1
        mutations = (
            ("RawLab/RawLab/Resources/Info.plist", f"<string>{ver}</string>", f"<string>{alt_ver}</string>"),
            ("RawLab/RawLab/Resources/Info.plist", f"<string>{build}</string>", f"<string>{alt_build_down}</string>"),
            ("RawLabMac/Info.plist", f"<string>{ver}</string>", f"<string>{alt_ver}</string>"),
            ("RawLabMac/Info.plist", f"<string>{build}</string>", f"<string>{alt_build_up}</string>"),
            ("RawLabAndroid/app/build.gradle.kts", f"versionCode = {build}", f"versionCode = {alt_build_down}"),
            ("RawLabAndroid/app/build.gradle.kts", f'versionName = "{ver}"', f'versionName = "{alt_ver}"'),
            ("RawLabWindows/RawLabWindows.csproj", f"<Version>{ver}</Version>", f"<Version>{alt_ver}</Version>"),
            (
                "RawLabWindows/RawLabWindows.csproj",
                f"<FileVersion>{ver}.{build}</FileVersion>",
                f"<FileVersion>{ver}.{alt_build_down}</FileVersion>",
            ),
            (
                "RawLabWindows/RawLabWindows.csproj",
                f"<InformationalVersion>{ver}+build.{build}</InformationalVersion>",
                f"<InformationalVersion>{ver}+build.{alt_build_down}</InformationalVersion>",
            ),
        )
        for rel, old, new in mutations:
            with self.subTest(file=rel, new=new), tempfile.TemporaryDirectory(prefix="rawlab-version-drift-") as tmp:
                root = Path(tmp)
                _copy_versioned_tree(root)
                target = root / rel
                original = target.read_text(encoding="utf-8")
                self.assertIn(old, original)
                mutated = original.replace(old, new, 1)
                target.write_text(mutated, encoding="utf-8")
                result = _run_generator(root, "--check")
                self.assertNotEqual(result.returncode, 0, f"Drift in {rel} ({new}) was not rejected")
                self.assertEqual(target.read_text(encoding="utf-8"), mutated)

    def test_invalid_version_source_fails_closed(self) -> None:
        bad_payloads = (
            "{not-json",
            json.dumps({"version": "0.10.0"}),
            json.dumps({"version": "0.10", "build": 19}),
            json.dumps({"version": "0.10.0", "build": "19"}),
            json.dumps({"version": "0.10.0", "build": 0}),
            json.dumps({"version": "0.10.0", "build": True}),
            json.dumps({"version": "0.10.0", "build": 70000}),
            json.dumps({"version": "0.10.0", "build": 19, "extra": 1}),
        )
        for payload in bad_payloads:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory(prefix="rawlab-version-bad-") as tmp:
                root = Path(tmp)
                _copy_versioned_tree(root)
                (root / "Shared/version.json").write_text(payload, encoding="utf-8")
                self.assertNotEqual(_run_generator(root, "--check").returncode, 0)
                self.assertNotEqual(_run_generator(root).returncode, 0)

    def test_print_mode_emits_version_and_build(self) -> None:
        source = json.loads((ROOT / "Shared/version.json").read_text(encoding="utf-8"))
        version_out = subprocess.check_output(
            [sys.executable, str(GENERATOR), "--print", "version"], text=True, cwd=ROOT
        ).strip()
        build_out = subprocess.check_output(
            [sys.executable, str(GENERATOR), "--print", "build"], text=True, cwd=ROOT
        ).strip()
        self.assertEqual(version_out, source["version"])
        self.assertEqual(build_out, str(source["build"]))

    def test_release_scripts_default_from_and_enforce_single_version_source(self) -> None:
        source = json.loads((ROOT / "Shared/version.json").read_text(encoding="utf-8"))
        expected_version = source["version"]
        expected_build = str(source["build"])

        base_env = {
            "RAWLAB_SPARKLE_PUBLIC_KEY": base64.b64encode(bytes(32)).decode(),
            "RAWLAB_UPDATE_CERTIFICATE_SHA256": "a" * 64,
        }
        resolved = macos_config.resolve_release_env(base_env, root=ROOT)
        cfg = macos_config.configuration(resolved, arch="x86_64")
        self.assertEqual(cfg["CFBundleShortVersionString"], expected_version)
        self.assertEqual(cfg["CFBundleVersion"], expected_build)

        with self.assertRaises(ValueError):
            macos_config.resolve_release_env(
                base_env | {"RAWLAB_RELEASE_VERSION": "9.9.9"}, root=ROOT
            )
        with self.assertRaises(ValueError):
            macos_config.resolve_release_env(
                base_env | {"RAWLAB_RELEASE_BUILD": "999"}, root=ROOT
            )

        # CLI validate defaults from Shared/version.json and fails on mismatch.
        ok = subprocess.run(
            [sys.executable, str(ROOT / "scripts/release/macos_config.py"), "validate", "x86_64"],
            env={
                "PATH": "",
                "RAWLAB_SPARKLE_PUBLIC_KEY": base_env["RAWLAB_SPARKLE_PUBLIC_KEY"],
                "RAWLAB_UPDATE_CERTIFICATE_SHA256": base_env["RAWLAB_UPDATE_CERTIFICATE_SHA256"],
            },
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)

        mismatch = subprocess.run(
            [sys.executable, str(ROOT / "scripts/release/macos_config.py"), "validate", "x86_64"],
            env={
                "PATH": "",
                "RAWLAB_RELEASE_VERSION": "0.0.1",
                "RAWLAB_SPARKLE_PUBLIC_KEY": base_env["RAWLAB_SPARKLE_PUBLIC_KEY"],
                "RAWLAB_UPDATE_CERTIFICATE_SHA256": base_env["RAWLAB_UPDATE_CERTIFICATE_SHA256"],
            },
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("Shared/version.json", mismatch.stderr)

        # Windows build.ps1 must stay ASCII-safe (PowerShell 5.1 requirement) and read Shared/version.json.
        build_ps1_bytes = (ROOT / "RawLabWindows/build.ps1").read_bytes()
        self.assertTrue(all(b <= 127 for b in build_ps1_bytes), "RawLabWindows/build.ps1 must stay ASCII-only")
        self.assertIn(b"Shared/version.json", build_ps1_bytes)

    def test_release_config_sh_defaults_from_shared_version_json(self) -> None:
        source = json.loads((ROOT / "Shared/version.json").read_text(encoding="utf-8"))
        env = {
            "PATH": "/usr/bin:/bin",
            "ROOT": str(ROOT),
            "ARCH": "x86_64",
            "PYTHON_EXECUTABLE": sys.executable,
            "RAWLAB_RELEASE": "1",
            "RAWLAB_CODESIGN_IDENTITY": "dummy-cert",
            "RAWLAB_SPARKLE_PUBLIC_KEY": base64.b64encode(bytes(32)).decode(),
            "RAWLAB_UPDATE_CERTIFICATE_SHA256": "a" * 64,
        }
        result = subprocess.run(
            [
                "bash",
                "-c",
                'set -euo pipefail; source "$ROOT/RawLabMac/release-config.sh"; printf "%s\\n%s\\n" "$RAWLAB_RELEASE_VERSION" "$RAWLAB_RELEASE_BUILD"',
            ],
            env=env,
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [source["version"], str(source["build"])])


if __name__ == "__main__":
    unittest.main()
