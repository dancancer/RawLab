"""Unit and contract tests for Shared/assets-manifest.json and scripts/assets/prepare.py."""
from __future__ import annotations

import errno
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PREPARE_PATH = ROOT / "scripts/assets/prepare.py"
SPEC = importlib.util.spec_from_file_location("assets_prepare", PREPARE_PATH)
PREPARE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PREPARE)


def _write_deterministic_targz(dest: Path, files: dict[str, bytes]) -> tuple[str, int]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("wb") as raw_out:
        with gzip.GzipFile(filename=dest.name, mode="wb", fileobj=raw_out, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w") as tf:
                for rel, content in sorted(files.items()):
                    ti = tarfile.TarInfo(name=rel)
                    ti.size = len(content)
                    ti.mtime = 0
                    ti.mode = 0o644
                    tf.addfile(ti, io.BytesIO(content))
    data = dest.read_bytes()
    return hashlib.sha256(data).hexdigest(), len(data)


class AssetsManifestAndPrepareTests(unittest.TestCase):
    def test_real_manifest_schema_and_bundled_catalog_parity(self) -> None:
        manifest = PREPARE.load_manifest(ROOT / "Shared/assets-manifest.json")
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["releaseTag"], "assets-v1")
        self.assertEqual(manifest.get("releasePolicy"), {"prerelease": True, "makeLatest": False})
        self.assertEqual(PREPARE.validate_release_policy(manifest), {"prerelease": True, "makeLatest": False})
        self.assertEqual(set(manifest["groups"]), {"luts", "raw"})

        luts = manifest["groups"]["luts"]
        raw = manifest["groups"]["raw"]
        self.assertEqual(len(luts["files"]), 59)
        self.assertEqual(len(raw["files"]), 1)
        self.assertEqual(raw["files"][0]["path"], "lutools/examples/DJI_20250602164503_0444_D.DNG")

        for group in (luts, raw):
            self.assertRegex(group["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(group["bytes"], 0)
            self.assertTrue(group["url"].startswith("https://github.com/dancancer/RawLab/releases/download/assets-v1/"))
            seen = set()
            for entry in group["files"]:
                self.assertNotIn(entry["path"], seen)
                seen.add(entry["path"])
                self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
                self.assertGreater(entry["bytes"], 0)

        # Verify BundledLooks catalog SHA-256s agree with the externalized asset manifest.
        manifest_by_path = {entry["path"]: entry["sha256"] for entry in luts["files"]}
        catalog = json.loads((ROOT / "Shared/BundledLooks/catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(len(catalog), 29)
        for item in catalog:
            rel = f"Shared/BundledLooks/{item['fileName']}"
            self.assertEqual(manifest_by_path.get(rel), item["sha256"], rel)

    def test_check_and_offline_materialization_with_copy_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            cache = root / "shared-cache"
            repo.mkdir()

            payload_a = b"LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"
            payload_b = b"RAW_FIXTURE_BYTES"
            luts_sha, luts_size = _write_deterministic_targz(
                cache / "placeholder" / "luts.tar.gz",
                {"Shared/BundledLooks/test.cube": payload_a},
            )
            raw_sha, raw_size = _write_deterministic_targz(
                cache / "placeholder" / "raw.tar.gz",
                {"lutools/examples/sample.DNG": payload_b},
            )
            # Place archives at the canonical <cache>/<archive_sha256>/<archive> location.
            (cache / luts_sha).mkdir(parents=True)
            (cache / raw_sha).mkdir(parents=True)
            (cache / "placeholder" / "luts.tar.gz").replace(cache / luts_sha / "luts.tar.gz")
            (cache / "placeholder" / "raw.tar.gz").replace(cache / raw_sha / "raw.tar.gz")

            manifest = {
                "schemaVersion": 1,
                "releaseTag": "assets-v1",
                "groups": {
                    "luts": {
                        "archive": "luts.tar.gz",
                        "url": "https://example.invalid/luts.tar.gz",
                        "sha256": luts_sha,
                        "bytes": luts_size,
                        "files": [{
                            "path": "Shared/BundledLooks/test.cube",
                            "sha256": hashlib.sha256(payload_a).hexdigest(),
                            "bytes": len(payload_a),
                        }],
                    },
                    "raw": {
                        "archive": "raw.tar.gz",
                        "url": "https://example.invalid/raw.tar.gz",
                        "sha256": raw_sha,
                        "bytes": raw_size,
                        "files": [{
                            "path": "lutools/examples/sample.DNG",
                            "sha256": hashlib.sha256(payload_b).hexdigest(),
                            "bytes": len(payload_b),
                        }],
                    },
                },
            }
            manifest_path = repo / "Shared/assets-manifest.json"
            manifest_path.parent.mkdir(parents=True)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            # Missing files must fail --check.
            self.assertEqual(
                PREPARE.main(["--group", "all", "--check", "--repo-root", str(repo), "--manifest", str(manifest_path)]),
                1,
            )

            # Materialize offline without network; also verify EXDEV fallback from os.link to shutil.copy2.
            with mock.patch.dict(os.environ, {"RAWLAB_ASSET_CACHE": str(cache)}), \
                    mock.patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")), \
                    mock.patch.object(PREPARE.os, "link", side_effect=OSError(errno.EXDEV, "cross-device")):
                rc = PREPARE.main([
                    "--group", "all", "--offline", "--quiet",
                    "--repo-root", str(repo), "--manifest", str(manifest_path),
                ])
            self.assertEqual(rc, 0)
            self.assertEqual((repo / "Shared/BundledLooks/test.cube").read_bytes(), payload_a)
            self.assertEqual((repo / "lutools/examples/sample.DNG").read_bytes(), payload_b)
            self.assertEqual(
                PREPARE.main(["--group", "all", "--check", "--quiet", "--repo-root", str(repo), "--manifest", str(manifest_path)]),
                0,
            )

            # Tampering a materialized file must fail --check and be repaired by re-running prepare.
            (repo / "Shared/BundledLooks/test.cube").write_bytes(b"corrupted")
            self.assertEqual(
                PREPARE.main(["--group", "luts", "--check", "--repo-root", str(repo), "--manifest", str(manifest_path)]),
                1,
            )
            with mock.patch.dict(os.environ, {"RAWLAB_ASSET_CACHE": str(cache)}):
                self.assertEqual(
                    PREPARE.main([
                        "--group", "luts", "--offline", "--quiet",
                        "--repo-root", str(repo), "--manifest", str(manifest_path),
                    ]),
                    0,
                )
            self.assertEqual((repo / "Shared/BundledLooks/test.cube").read_bytes(), payload_a)

    def test_corrupted_cached_archive_is_rejected_in_offline_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            cache = root / "shared-cache"
            repo.mkdir()
            expected_sha = "a" * 64
            (cache / expected_sha).mkdir(parents=True)
            (cache / expected_sha / "bad.tar.gz").write_bytes(b"not a valid archive")
            manifest = {
                "schemaVersion": 1,
                "releaseTag": "assets-v1",
                "groups": {
                    "raw": {
                        "archive": "bad.tar.gz",
                        "url": "https://example.invalid/bad.tar.gz",
                        "sha256": expected_sha,
                        "bytes": 19,
                        "files": [{"path": "lutools/examples/sample.DNG", "sha256": "b" * 64, "bytes": 4}],
                    }
                },
            }
            manifest_path = repo / "Shared/assets-manifest.json"
            manifest_path.parent.mkdir(parents=True)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with mock.patch.dict(os.environ, {"RAWLAB_ASSET_CACHE": str(cache)}):
                with self.assertRaisesRegex(RuntimeError, "Missing cached archive"):
                    PREPARE.main([
                        "--group", "raw", "--offline", "--quiet",
                        "--repo-root", str(repo), "--manifest", str(manifest_path),
                    ])
            # Corrupted archive must have been deleted rather than kept.
            self.assertFalse((cache / expected_sha / "bad.tar.gz").exists())

    def test_resolve_cache_root_uses_git_common_dir_across_worktrees(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            main_repo = base / "main-repo"
            main_repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=main_repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=main_repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=main_repo, check=True)
            (main_repo / "README.md").write_text("hi\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=main_repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=main_repo, check=True)

            wt = base / "wt-1"
            subprocess.run(["git", "worktree", "add", "-q", "-b", "wt-branch", str(wt)], cwd=main_repo, check=True)
            try:
                resolved = PREPARE.resolve_cache_root(wt, env={})
                self.assertEqual(resolved, (main_repo / ".cache/shared/assets").resolve())
            finally:
                subprocess.run(["git", "worktree", "remove", "--force", str(wt)], cwd=main_repo, check=True)

    def test_release_policy_and_gh_release_args_guard_against_hijacking_latest(self) -> None:
        manifest_path = ROOT / "Shared/assets-manifest.json"
        manifest = PREPARE.load_manifest(manifest_path)

        create_cmd = PREPARE.build_gh_release_args(
            manifest,
            "create",
            title="Externalized LUT & RAW assets (v1)",
            files=["rawlab-luts-v1.tar.gz"],
        )
        self.assertEqual(
            create_cmd,
            [
                "gh",
                "release",
                "create",
                "assets-v1",
                "--prerelease",
                "--latest=false",
                "--title",
                "Externalized LUT & RAW assets (v1)",
                "rawlab-luts-v1.tar.gz",
            ],
        )
        edit_cmd = PREPARE.build_gh_release_args(manifest, "edit")
        self.assertEqual(edit_cmd, ["gh", "release", "edit", "assets-v1", "--prerelease", "--latest=false"])

        cli_ok = subprocess.run(
            [sys.executable, str(PREPARE_PATH), "--check-release-policy", "--manifest", str(manifest_path)],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertEqual(cli_ok.returncode, 0, cli_ok.stdout + cli_ok.stderr)

        cli_print = subprocess.run(
            [sys.executable, str(PREPARE_PATH), "--print-gh-release-args", "edit", "--manifest", str(manifest_path)],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertEqual(cli_print.returncode, 0, cli_print.stdout + cli_print.stderr)
        self.assertIn("--prerelease", cli_print.stdout)
        self.assertIn("--latest=false", cli_print.stdout)

        bad_policies = [
            None,
            {},
            {"prerelease": True},
            {"makeLatest": False},
            {"prerelease": False, "makeLatest": False},
            {"prerelease": True, "makeLatest": True},
            {"prerelease": "true", "makeLatest": False},
            {"prerelease": True, "makeLatest": "false"},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            bad_path = Path(tmp) / "assets-manifest.json"
            for bad_policy in bad_policies:
                mutated = json.loads(manifest_path.read_text(encoding="utf-8"))
                if bad_policy is None:
                    mutated.pop("releasePolicy", None)
                else:
                    mutated["releasePolicy"] = bad_policy
                bad_path.write_text(json.dumps(mutated), encoding="utf-8")

                with self.subTest(bad_policy=bad_policy):
                    with self.assertRaises(ValueError):
                        PREPARE.validate_release_policy(mutated)
                    with self.assertRaises(ValueError):
                        PREPARE.build_gh_release_args(mutated, "create")
                    res = subprocess.run(
                        [sys.executable, str(PREPARE_PATH), "--check-release-policy", "--manifest", str(bad_path)],
                        capture_output=True,
                        text=True,
                        cwd=ROOT,
                    )
                    self.assertNotEqual(res.returncode, 0)
                    print_res = subprocess.run(
                        [sys.executable, str(PREPARE_PATH), "--print-gh-release-args", "create", "--manifest", str(bad_path)],
                        capture_output=True,
                        text=True,
                        cwd=ROOT,
                    )
                    self.assertNotEqual(print_res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
