"""Tests for deterministic DualDn platform archives and their verification contract."""
from __future__ import annotations

import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_PATH = ROOT / "scripts/assets/package_ai_models.py"
BUILD_PS = ROOT / "RawLabWindows/build.ps1"
SPEC = importlib.util.spec_from_file_location("package_ai_models", PACKAGE_PATH)
PACKAGE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PACKAGE)


def _file_record(path: Path) -> dict:
    digest, size = PACKAGE._sha256_file(path)
    return {"bytes": size, "sha256": digest}


def _write_coreml_model(root: Path, name: str, *, require_precision: bool = False) -> dict:
    directory = f"{name}.mlmodelc"
    contents = {
        "analytics/coremldata.bin": f"{name} analytics".encode(),
        "coremldata.bin": f"{name} metadata".encode(),
        "model.mil": f"fake {name} model".encode(),
        "weights/weight.bin": f"{name} weights".encode(),
    }
    entries = []
    for relative, data in contents.items():
        path = root / directory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        entries.append({"path": relative, **_file_record(path)})
    record = {"directory": directory, "files": entries}
    if require_precision:
        record["precision"] = "float32"
    return record


def _make_model_tree(root: Path) -> dict:
    root.mkdir(parents=True)
    for name in ("raw", "isp", "rgb", "blind_rgb"):
        (root / f"{name}.onnx").write_bytes(f"tiny fake {name} ONNX".encode())
    (root / "DualDn-LICENSE.txt").write_text("synthetic DualDn license fixture\n", encoding="utf-8")
    restormer_license = ROOT / "lutools/tests/fixtures/restormer-v1-LICENSE.txt"
    shutil.copyfile(restormer_license, root / "Restormer-LICENSE.txt")
    graphs = {
        name: {"file": f"{name}.onnx", **_file_record(root / f"{name}.onnx")}
        for name in ("raw", "isp", "rgb")
    }
    constants = PACKAGE._model_package_constants()
    blind_rgb = {
        "model_id": "restormer-real-srgb-v1",
        "protocol": "rawlab-scene-rgb-v1",
        "source_revision": constants["restormerSourceRevision"],
        "weights_sha256": constants["restormerWeightsSHA256"],
        "tile_size": 640,
        "core": 512,
        "halo": 64,
        "input": "encoded_rgb",
        "output": "denoised_rgb",
        "file": "blind_rgb.onnx",
        **_file_record(root / "blind_rgb.onnx"),
        "license_file": "Restormer-LICENSE.txt",
        "license_sha256": constants["restormerLicenseSHA256"],
    }
    blind_rgb["coreml"] = _write_coreml_model(root, "blind_rgb", require_precision=True)
    manifest = {
        "format_version": 1,
        "protocol": "rawlab-dualdn-v1",
        "model_id": "dualdn-big-restormer-v1",
        "source_revision": constants["dualdnSourceRevision"],
        "weights_sha256": constants["dualdnWeightsSHA256"],
        "tile_size": 640,
        "production_geometry": True,
        "raw_core": 384,
        "raw_halo": 128,
        "rgb_core": 512,
        "rgb_halo": 64,
        "packed_order": ["R", "G_top", "G_bottom", "B"],
        "input_floor": 1e-8,
        "variance_floor": 1e-7,
        "sigma_semantics": "variance",
        "isp": {"demosaic": "AHD", "gamma": "Rec709", "reference": "D65", "alpha": 0, "bgu": False},
        "graphs": graphs,
        "coreml": {
            "format": "mlmodelc",
            "precision": "float32",
            "raw": _write_coreml_model(root, "raw"),
            "rgb": _write_coreml_model(root, "rgb"),
        },
        "blind_rgb": blind_rgb,
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    # A recognized CI tensor fixture is a source input, never an archive member.
    (root / "raw-b.f32").write_bytes(b"synthetic test tensor")
    return manifest


def _tree_snapshot(root: Path) -> dict[str, tuple[str, int, str | None]]:
    snapshot = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot[relative] = ("symlink", 0, os.readlink(path))
        elif path.is_dir():
            snapshot[relative] = ("directory", 0, None)
        else:
            digest, size = PACKAGE._sha256_file(path)
            snapshot[relative] = ("file", size, digest)
    return snapshot


def _canonical_archive(tree: Path, platform: str, directory: Path) -> tuple[Path, dict]:
    staged = PACKAGE.create_model_archive(tree, directory / "staged.tar.gz")
    digest, _ = PACKAGE._sha256_file(staged)
    archive = directory / f"rawlab-ai-{platform}-{digest[:12]}.tar.gz"
    os.replace(staged, archive)
    return archive, PACKAGE.describe_model_archive(archive, platform)


def _write_tar(path: Path, specs: list[dict]) -> None:
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for spec in specs:
                    info = tarfile.TarInfo(spec["name"])
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.mode = 0o755 if spec["kind"] == "directory" else 0o644
                    kind = spec["kind"]
                    if kind == "directory":
                        info.type = tarfile.DIRTYPE
                        info.size = 0
                        tar.addfile(info)
                    elif kind == "symlink":
                        info.type = tarfile.SYMTYPE
                        info.linkname = spec["linkname"]
                        tar.addfile(info)
                    elif kind == "hardlink":
                        info.type = tarfile.LNKTYPE
                        info.linkname = spec["linkname"]
                        tar.addfile(info)
                    elif kind == "fifo":
                        info.type = tarfile.FIFOTYPE
                        tar.addfile(info)
                    else:
                        data = spec["data"]
                        info.type = tarfile.REGTYPE
                        info.size = len(data)
                        tar.addfile(info, io.BytesIO(data))


def _matching_description(
    candidate: Path, platform: str, entries: list[dict], manifest_bytes: bytes
) -> tuple[Path, dict]:
    digest, size = PACKAGE._sha256_file(candidate)
    archive = candidate.with_name(f"rawlab-ai-{platform}-{digest[:12]}.tar.gz")
    os.replace(candidate, archive)
    unpacked_bytes = sum(entry["bytes"] for entry in entries if entry["kind"] == "file")
    return archive, {
        "schemaVersion": 1,
        "platform": platform,
        "archiveName": archive.name,
        "archiveSha256": digest,
        "archiveBytes": size,
        "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "unpackedBytes": unpacked_bytes,
        "entries": entries,
    }


class PackageAIModelsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.manifest = _make_model_tree(self.source)

    def _prepare(self, platform: str) -> Path:
        destination = self.root / f"tree-{platform}"
        return PACKAGE.prepare_model_tree(self.source, platform, destination)

    def test_platform_allow_lists_determinism_and_source_immutability(self) -> None:
        before = _tree_snapshot(self.source)
        for platform in PACKAGE.PLATFORMS:
            with self.subTest(platform=platform):
                tree = self._prepare(platform)
                tree_files = {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_file()}
                required = {"manifest.json", *PACKAGE.BASE_FILES}
                self.assertTrue(required.issubset(tree_files))
                self.assertNotIn("raw-b.f32", tree_files)
                expected_files = {
                    path.relative_to(self.source).as_posix()
                    for path in self.source.rglob("*")
                    if path.is_file() and path.name not in PACKAGE.SOURCE_ONLY_TEST_TENSORS
                }
                if platform == "windows-x64":
                    expected_files = required
                self.assertEqual(tree_files, expected_files)
                final_manifest = json.loads((tree / "manifest.json").read_text(encoding="utf-8"))
                if platform == "macos-arm64":
                    self.assertEqual(
                        {name for name in tree_files if name.endswith(".mlmodelc/model.mil")},
                        {"raw.mlmodelc/model.mil", "rgb.mlmodelc/model.mil", "blind_rgb.mlmodelc/model.mil"},
                    )
                    self.assertIn("coreml", final_manifest)
                    self.assertIn("coreml", final_manifest["blind_rgb"])
                else:
                    self.assertEqual(
                        {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_dir()},
                        set(),
                    )
                    self.assertNotIn("coreml", final_manifest)
                    self.assertNotIn("coreml", final_manifest["blind_rgb"])
                first, description = _canonical_archive(tree, platform, self.root / f"first-{platform}")
                second, _ = _canonical_archive(tree, platform, self.root / f"second-{platform}")
                self.assertEqual(first.read_bytes(), second.read_bytes())
                self.assertEqual(description["archiveName"], first.name)
                self.assertGreater(description["archiveBytes"], 0)
                self.assertGreater(description["unpackedBytes"], 0)
                PACKAGE.verify_model_archive(first, description)
        self.assertEqual(_tree_snapshot(self.source), before)

    def test_windows_manifest_transform_is_pinned_to_build_ps1(self) -> None:
        transformed = PACKAGE.strip_coreml_fields(self.manifest)
        expected = copy.deepcopy(self.manifest)
        expected.pop("coreml")
        expected["blind_rgb"].pop("coreml")
        self.assertEqual(transformed, expected)

        build_script = BUILD_PS.read_text(encoding="utf-8")
        self.assertIn("$aiManifest.PSObject.Properties.Remove('coreml')", build_script)
        self.assertIn("$aiManifest.blind_rgb.PSObject.Properties.Remove('coreml')", build_script)
        self.assertEqual(
            re.findall(r"PSObject\.Properties\.Remove\('([^']+)'\)", build_script),
            ["coreml", "coreml"],
        )
        self.assertIn("ConvertTo-Json -Depth 100", build_script)
        self.assertIn("Set-Content -LiteralPath \"$aiDestination/manifest.json\" -Encoding utf8", build_script)
        windows_tree = self._prepare("windows-x64")
        self.assertEqual(
            json.loads((windows_tree / "manifest.json").read_text(encoding="utf-8")),
            expected,
        )

    def test_rejects_unlisted_source_file(self) -> None:
        (self.source / "unexpected.onnx").write_bytes(b"not in the model allow-list")
        with self.assertRaisesRegex(ValueError, "allow-list"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.root / "bad-tree")

    def test_rejects_source_symlink(self) -> None:
        (self.source / "unexpected-link").symlink_to(self.source / "raw.onnx")
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            PACKAGE.prepare_model_tree(self.source, "windows-x64", self.root / "bad-tree")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO special files are unavailable on this platform")
    def test_rejects_source_special_file(self) -> None:
        os.mkfifo(self.source / "unexpected-fifo")
        with self.assertRaisesRegex(ValueError, "special file"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.root / "bad-tree")

    def test_rejects_missing_required_file(self) -> None:
        (self.source / "blind_rgb.onnx").unlink()
        with self.assertRaisesRegex(ValueError, "Missing required model file"):
            PACKAGE.prepare_model_tree(self.source, "windows-x64", self.root / "bad-tree")

    def test_rejects_manifest_digest_mismatch(self) -> None:
        with (self.source / "raw.onnx").open("ab") as output:
            output.write(b"changed")
        with self.assertRaisesRegex(ValueError, "Manifest digest mismatch"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.root / "bad-tree")

    def test_rejects_output_path_inside_source(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside source model directory"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.source / "generated")
        self.assertFalse((self.source / "generated").exists())

    def _good_mac_archive(self) -> tuple[Path, dict]:
        tree = self._prepare("macos-arm64")
        return _canonical_archive(tree, "macos-arm64", self.root / "good")

    def _write_member_archive(self, specs: list[dict]) -> tuple[Path, dict]:
        candidate = self.root / "malformed.tar.gz"
        _write_tar(candidate, specs)
        entries = []
        for spec in specs:
            if spec["kind"] == "directory":
                entries.append({"path": spec["name"], "kind": "directory", "bytes": 0})
            elif spec["kind"] in ("file", "regular"):
                data = spec["data"]
                entries.append({
                    "path": spec["name"],
                    "kind": "file",
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                })
            else:
                entries.append({
                    "path": spec["name"],
                    "kind": "file",
                    "bytes": 0,
                    "sha256": hashlib.sha256(b"").hexdigest(),
                })
        entries.sort(key=lambda entry: entry["path"])
        return _matching_description(candidate, "macos-arm64", entries, b"{}")

    def test_verify_rejects_archive_digest_size_and_member_set_mismatches(self) -> None:
        archive, description = self._good_mac_archive()
        bad_digest = copy.deepcopy(description)
        bad_digest["archiveSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            PACKAGE.verify_model_archive(archive, bad_digest)
        bad_size = copy.deepcopy(description)
        bad_size["archiveBytes"] += 1
        with self.assertRaisesRegex(ValueError, "size mismatch"):
            PACKAGE.verify_model_archive(archive, bad_size)
        bad_manifest = copy.deepcopy(description)
        bad_manifest["manifestSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Manifest SHA-256 mismatch"):
            PACKAGE.verify_model_archive(archive, bad_manifest)
        bad_unpacked = copy.deepcopy(description)
        bad_unpacked["unpackedBytes"] += 1
        with self.assertRaisesRegex(ValueError, "Unpacked size mismatch"):
            PACKAGE.verify_model_archive(archive, bad_unpacked)

        specs = []
        with tarfile.open(archive, mode="r:gz") as source_tar:
            for member in source_tar:
                if member.isdir():
                    specs.append({"name": member.name, "kind": "directory"})
                else:
                    stream = source_tar.extractfile(member)
                    assert stream is not None
                    specs.append({"name": member.name, "kind": "file", "data": stream.read()})
        specs.append({"name": "extra.txt", "kind": "file", "data": b"extra"})
        candidate = self.root / "extra.tar.gz"
        _write_tar(candidate, specs)
        extra_archive, wrong_members = _matching_description(candidate, "macos-arm64", description["entries"], b"{}")
        wrong_members["manifestSha256"] = description["manifestSha256"]
        wrong_members["unpackedBytes"] += len(b"extra")
        with self.assertRaisesRegex(ValueError, "members do not match"):
            PACKAGE.verify_model_archive(extra_archive, wrong_members)

    def test_verify_rejects_unsafe_paths_links_duplicates_and_case_collisions(self) -> None:
        good_manifest = {"name": "manifest.json", "kind": "file", "data": b"{}"}
        cases = (
            ("absolute path", {"name": "/outside", "kind": "file", "data": b"x"}),
            ("parent path", {"name": "../outside", "kind": "file", "data": b"x"}),
            ("symbolic link", {"name": "linked", "kind": "symlink", "linkname": "manifest.json"}),
            ("hard link", {"name": "linked", "kind": "hardlink", "linkname": "manifest.json"}),
            ("duplicate path", {"name": "same", "kind": "file", "data": b"one"}),
            ("case collision", {"name": "Name", "kind": "file", "data": b"one"}),
            ("special file", {"name": "pipe", "kind": "fifo"}),
        )
        for label, invalid in cases:
            with self.subTest(case=label):
                specs = [good_manifest, invalid]
                if label == "duplicate path":
                    specs.append({"name": "same", "kind": "file", "data": b"two"})
                elif label == "case collision":
                    specs.append({"name": "name", "kind": "file", "data": b"two"})
                archive, description = self._write_member_archive(specs)
                with self.assertRaises(ValueError):
                    PACKAGE.verify_model_archive(archive, description)


if __name__ == "__main__":
    unittest.main()
