"""Synthetic tests for deterministic AI model archives and their verification contract."""
from __future__ import annotations

import contextlib
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_PATH = ROOT / "scripts/assets/package_ai_models.py"
SPEC = importlib.util.spec_from_file_location("package_ai_models", PACKAGE_PATH)
PACKAGE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PACKAGE)


def _record(data: bytes) -> dict:
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def _add_file(root: Path, relative: str, data: bytes) -> dict:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return _record(data)


def _make_model_tree(root: Path) -> dict:
    root.mkdir(parents=True)
    graphs = {}
    for name in ("raw", "isp", "rgb"):
        data = f"synthetic {name} ONNX\n".encode()
        graphs[name] = {"file": f"{name}.onnx", **_add_file(root, f"{name}.onnx", data)}
    blind_rgb_data = b"synthetic blind_rgb ONNX\n"
    blind_rgb_record = {"file": "blind_rgb.onnx", **_add_file(root, "blind_rgb.onnx", blind_rgb_data)}
    (root / "DualDn-LICENSE.txt").write_text("DualDn licence fixture\n", encoding="utf-8")
    (root / "Restormer-LICENSE.txt").write_text("Restormer licence fixture\n", encoding="utf-8")

    def coreml_record(directory: str) -> dict:
        entries = []
        for relative, data in (
            ("model.mil", f"{directory} model".encode()),
            ("weights/weight.bin", f"{directory} weights".encode()),
        ):
            entries.append({"path": relative, **_add_file(root, f"{directory}/{relative}", data)})
        return {"directory": directory, "files": entries}

    manifest = {
        "format_version": True,
        "production_geometry": 1,
        "isp": {"alpha": False, "bgu": 0},
        "graphs": {**graphs, "extra_uninterpreted_field": {"future": "allowed"}},
        "coreml": {"raw": coreml_record("raw.mlmodelc"), "rgb": coreml_record("rgb.mlmodelc")},
        "blind_rgb": {
            **blind_rgb_record,
            "coreml": coreml_record("blind_rgb.mlmodelc"),
        },
    }
    (root / "manifest.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
    # A known source-only test tensor is accepted as input but is not packaged.
    (root / "raw-b.f32").write_bytes(b"synthetic tensor")
    return manifest


def _canonical_archive(tree: Path, platform: str, directory: Path) -> tuple[Path, dict]:
    staged = PACKAGE.create_model_archive(tree, directory / "staged.tar.gz")
    digest, _ = PACKAGE._sha256_file(staged)
    archive = directory / f"rawlab-ai-{platform}-{digest[:12]}.tar.gz"
    os.replace(staged, archive)
    return archive, PACKAGE.describe_model_archive(archive, platform)


def _write_tar(specs: list[dict], *, tar_format: int = tarfile.USTAR_FORMAT) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tar_format) as tar:
            for spec in specs:
                info = tarfile.TarInfo(spec["name"])
                info.mtime = 0
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mode = 0o755 if spec["kind"] == "directory" else 0o644
                info.pax_headers = spec.get("pax_headers", {})
                kind = spec["kind"]
                if kind == "directory":
                    info.type = tarfile.DIRTYPE
                    info.size = 0
                    tar.addfile(info)
                elif kind in ("symlink", "hardlink"):
                    info.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
                    info.linkname = spec.get("linkname", "manifest.json")
                    tar.addfile(info)
                elif kind == "fifo":
                    info.type = tarfile.FIFOTYPE
                    tar.addfile(info)
                elif kind == "char-device":
                    info.type = tarfile.CHRTYPE
                    info.devmajor = 1
                    info.devminor = 2
                    tar.addfile(info)
                else:
                    data = spec["data"]
                    info.type = spec.get("type", tarfile.REGTYPE)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
    return output.getvalue()


def _gzip_tar(raw_tar: bytes) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
        compressed.write(raw_tar)
    return output.getvalue()


def _matching_description(
    directory: Path,
    compressed: bytes,
    entries: list[dict],
    manifest: bytes = b"{}",
) -> tuple[Path, dict]:
    candidate = directory / "candidate.tar.gz"
    candidate.write_bytes(compressed)
    digest, size = PACKAGE._sha256_file(candidate)
    archive = directory / f"rawlab-ai-windows-x64-{digest[:12]}.tar.gz"
    os.replace(candidate, archive)
    return archive, {
        "schemaVersion": 1,
        "platform": "windows-x64",
        "archiveName": archive.name,
        "archiveSha256": digest,
        "archiveBytes": size,
        "manifestSha256": hashlib.sha256(manifest).hexdigest(),
        "unpackedBytes": sum(entry["bytes"] for entry in entries if entry["kind"] == "file"),
        "entries": entries,
    }


def _entry(name: str, data: bytes, *, kind: str = "file") -> dict:
    result = {"path": name, "kind": kind, "bytes": len(data) if kind == "file" else 0}
    if kind == "file":
        result["sha256"] = hashlib.sha256(data).hexdigest()
    return result


def _rechecksum_header(block: bytearray) -> None:
    block[148:156] = b"        "
    checksum = sum(block)
    block[148:156] = f"{checksum:06o}\0 ".encode("ascii")


class PackageAIModelsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.manifest = _make_model_tree(self.source)

    def _prepare(self, platform: str = "macos-arm64") -> Path:
        destination = self.root / f"tree-{platform}"
        return PACKAGE.prepare_model_tree(self.source, platform, destination)

    def _crafted(self, specs: list[dict], entries: list[dict] | None = None) -> tuple[Path, dict]:
        manifest = next((spec["data"] for spec in specs if spec["name"] == "manifest.json"), b"{}")
        description_entries = entries if entries is not None else [
            _entry(spec["name"], spec.get("data", b""), kind="directory" if spec["kind"] == "directory" else "file")
            for spec in specs
        ]
        description_entries.sort(key=lambda entry: entry["path"])
        return _matching_description(self.root, _write_tar(specs), description_entries, manifest)

    def test_prepare_exact_files_manifest_drift_and_empty_coreml_directories(self) -> None:
        (self.source / "raw.mlmodelc/empty/nested").mkdir(parents=True)
        for platform in PACKAGE.PLATFORMS:
            with self.subTest(platform=platform):
                tree = self._prepare(platform)
                files = {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_file()}
                expected = {"manifest.json", *PACKAGE._manifest_file_records(
                    PACKAGE.strip_coreml_fields(self.manifest) if platform == "windows-x64" else self.manifest
                ), *PACKAGE.LICENSE_FILES}
                self.assertEqual(files, expected)
                self.assertFalse((tree / "raw.mlmodelc/empty").exists())
                # Protocol field types and unknown graph keys are core semantics, not packer decisions.
                self.assertIs(json.loads((tree / "manifest.json").read_text())["format_version"], True)
                self.assertIn("extra_uninterpreted_field", json.loads((tree / "manifest.json").read_text())["graphs"])

    def test_rejects_manifest_file_digest_mismatch_and_empty_license(self) -> None:
        with (self.source / "raw.onnx").open("ab") as output:
            output.write(b"changed")
        with self.assertRaisesRegex(ValueError, "Manifest digest mismatch for raw.onnx"):
            PACKAGE.validate_model_tree(self.source, "windows-x64", source_package=True)

        raw_data = b"synthetic raw ONNX\n"
        (self.source / "raw.onnx").write_bytes(raw_data)
        self.manifest["graphs"]["raw"].update(_record(raw_data))
        (self.source / "manifest.json").write_text(json.dumps(self.manifest, separators=(",", ":")) + "\n")
        (self.source / "DualDn-LICENSE.txt").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "Required licence is empty: DualDn-LICENSE.txt"):
            PACKAGE.validate_model_tree(self.source, "windows-x64", source_package=True)

    def test_rejects_source_root_and_inner_directory_symlinks(self) -> None:
        root_link = self.root / "source-link"
        root_link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic-link model directory"):
            PACKAGE.prepare_model_tree(root_link, "macos-arm64", self.root / "root-link-out")

        inner = self.source / "raw.mlmodelc/linked-directory"
        inner.symlink_to(self.source / "raw.mlmodelc/weights", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic link in model directory"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.root / "inner-link-out")

    def test_rejects_output_inside_equal_or_symlinked_to_source(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside source model directory"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.source / "nested-output")
        with self.assertRaisesRegex(ValueError, "outside source model directory"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", self.source)
        source_alias = self.root / "source-alias"
        source_alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "outside source model directory"):
            PACKAGE.prepare_model_tree(self.source, "macos-arm64", source_alias / "through-link")
        with self.assertRaisesRegex(ValueError, "outside model tree"):
            PACKAGE.create_model_archive(self.source, source_alias / "inside.tar.gz")

    def test_rejects_source_special_file(self) -> None:
        if not hasattr(os, "mkfifo"):
            self.skipTest("FIFO special files are unavailable on this platform")
        os.mkfifo(self.source / "unexpected-fifo")
        with self.assertRaisesRegex(ValueError, "Refusing special file in model directory"):
            PACKAGE.validate_model_tree(self.source, "windows-x64", source_package=True)

    def test_determinism_and_fixed_gzip_tar_metadata(self) -> None:
        source_tree = self._prepare("windows-x64")
        trees = [self.root / "ordered-a", self.root / "ordered-b"]
        paths = list(source_tree.rglob("*"))
        for index, tree in enumerate(trees):
            tree.mkdir()
            all_paths = sorted(paths, key=lambda path: path.relative_to(source_tree).as_posix(), reverse=bool(index))
            for path in all_paths:
                relative = path.relative_to(source_tree)
                target = tree / relative
                if path.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    target.chmod(0o700 if index else 0o755)
                    os.utime(target, (1_600_000_000 + index, 1_600_000_000 + index))
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(path.read_bytes())
                    target.chmod(0o600 if index else 0o644)
                    os.utime(target, (1_600_000_100 + index, 1_600_000_100 + index))

        worker = r'''import importlib.util, os, pathlib, sys, tarfile
spec = importlib.util.spec_from_file_location("pkg", sys.argv[1])
pkg = importlib.util.module_from_spec(spec); spec.loader.exec_module(pkg)
base = tarfile.TarInfo
class HostileTarInfo(base):
    def __init__(self, name=""):
        super().__init__(name)
        self.mode, self.uid, self.gid = 0o600, 31, 42
        self.mtime, self.uname, self.gname = 123456, "host", "group"
tarfile.TarInfo = HostileTarInfo
os.umask(int(sys.argv[4], 8))
pkg.create_model_archive(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
'''
        archives = []
        for index, tree in enumerate(trees):
            archive = self.root / f"deterministic-{index}.tar.gz"
            subprocess.run(
                [sys.executable, "-c", worker, str(PACKAGE_PATH), str(tree), str(archive), "022" if index == 0 else "077"],
                check=True,
            )
            archives.append(archive)
        first, second = (archive.read_bytes() for archive in archives)
        self.assertEqual(first, second)
        self.assertEqual(first[:10], b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff")
        with gzip.GzipFile(fileobj=io.BytesIO(first), mode="rb") as compressed:
            raw_tar = compressed.read()
        with tarfile.open(fileobj=io.BytesIO(raw_tar), mode="r:") as tar:
            members = tar.getmembers()
        self.assertTrue(members)
        for member in members:
            self.assertEqual(member.uid, 0)
            self.assertEqual(member.gid, 0)
            self.assertEqual(member.mtime, 0)
            self.assertEqual(member.uname, "")
            self.assertEqual(member.gname, "")
            self.assertEqual(member.mode, 0o755 if member.isdir() else 0o644)

    def test_archive_round_trip_and_canonical_verification(self) -> None:
        tree = self._prepare("macos-arm64")
        archive, description = _canonical_archive(tree, "macos-arm64", self.root / "canonical")
        PACKAGE.verify_model_archive(archive, description)

    def test_digest_mismatch_stops_before_archive_parsing(self) -> None:
        tree = self._prepare("windows-x64")
        archive, description = _canonical_archive(tree, "windows-x64", self.root / "digest")
        data = bytearray(archive.read_bytes())
        data[len(data) // 2] ^= 1
        archive.write_bytes(data)
        with mock.patch.object(PACKAGE, "_archive_inventory", side_effect=AssertionError("parsed archive")) as inspect:
            with self.assertRaisesRegex(ValueError, "Archive SHA-256 mismatch"):
                PACKAGE.verify_model_archive(archive, description)
            inspect.assert_not_called()

    def test_verify_checks_size_before_hash_or_parsing(self) -> None:
        tree = self._prepare("windows-x64")
        archive, description = _canonical_archive(tree, "windows-x64", self.root / "size-first")
        bad = copy.deepcopy(description)
        bad["archiveBytes"] += 1
        bad["archiveSha256"] = "invalid"
        with mock.patch.object(PACKAGE, "_sha256_stream", side_effect=AssertionError("hashed archive")):
            with self.assertRaisesRegex(ValueError, "Archive size mismatch"):
                PACKAGE.verify_model_archive(archive, bad)

    def test_rejects_noncanonical_members_outside_description(self) -> None:
        specs = [
            {"name": "actual.txt", "kind": "file", "data": b"content"},
            {"name": "manifest.json", "kind": "file", "data": b"{}"},
        ]
        wrong_entries = [_entry("manifest.json", b"{}"), _entry("described.txt", b"content")]
        archive, description = self._crafted(specs, wrong_entries)
        with self.assertRaisesRegex(ValueError, "Archive members do not match the description"):
            PACKAGE.verify_model_archive(archive, description)

    def test_rejects_trailing_bytes_after_gzip_member(self) -> None:
        raw_tar = gzip.decompress(_write_tar([{"name": "manifest.json", "kind": "file", "data": b"{}"}]))
        entries = [_entry("manifest.json", b"{}")]
        archive, description = _matching_description(self.root, _gzip_tar(raw_tar) + b"TRAILING", entries)
        with self.assertRaisesRegex(ValueError, "Trailing bytes after gzip member"):
            PACKAGE.verify_model_archive(archive, description)

    def test_rejects_second_gzip_member(self) -> None:
        first = _write_tar([{"name": "manifest.json", "kind": "file", "data": b"{}"}])
        entries = [_entry("manifest.json", b"{}")]
        archive, description = _matching_description(self.root, first + gzip.compress(b"extra", mtime=0), entries)
        with self.assertRaisesRegex(ValueError, "Multiple gzip members"):
            PACKAGE.verify_model_archive(archive, description)

    def test_rejects_damaged_gzip_trailer(self) -> None:
        compressed = bytearray(_write_tar([{"name": "manifest.json", "kind": "file", "data": b"{}"}]))
        compressed[-8] ^= 1
        archive, description = _matching_description(
            self.root, bytes(compressed), [_entry("manifest.json", b"{}")]
        )
        with self.assertRaisesRegex(ValueError, "Invalid gzip stream"):
            PACKAGE.verify_model_archive(archive, description)

    def test_rejects_tar_entry_after_end_blocks(self) -> None:
        original = gzip.decompress(_write_tar([{"name": "manifest.json", "kind": "file", "data": b"{}"}]))
        extra = gzip.decompress(_write_tar([{"name": "later.txt", "kind": "file", "data": b"later"}]))[:1024]
        archive, description = _matching_description(
            self.root,
            _gzip_tar(original + extra),
            [_entry("manifest.json", b"{}")],
        )
        with self.assertRaisesRegex(ValueError, "exceeds the described member limits"):
            PACKAGE.verify_model_archive(archive, description)

    def test_verify_accepts_builder_output_at_every_record_padding(self) -> None:
        # tarfile 在两个结束块之后再补齐到 10240 字节，补齐量随内容长度变化；逐个 512 字节块走一遍整条记录。
        tree = self.root / "padding-tree"
        tree.mkdir()
        for blocks in range(1, 2 * tarfile.RECORDSIZE // 512 + 2):
            with self.subTest(manifest_bytes=blocks * 512 - 7):
                (tree / "manifest.json").write_bytes(b"{" + b" " * (blocks * 512 - 9) + b"}")
                output = self.root / f"padding-{blocks}"
                output.mkdir()
                candidate = PACKAGE.create_model_archive(tree, output / "candidate.tar.gz")
                digest, _ = PACKAGE._sha256_file(candidate)
                archive = output / f"rawlab-ai-windows-x64-{digest[:12]}.tar.gz"
                os.replace(candidate, archive)
                PACKAGE.verify_model_archive(archive, PACKAGE.describe_model_archive(archive, "windows-x64"))

    def test_platform_packages_must_be_complete(self) -> None:
        mac_tree = self._prepare("macos-arm64")
        PACKAGE.validate_model_tree(mac_tree, "macos-arm64")
        with self.assertRaisesRegex(ValueError, "windows-x64 package must not contain Core ML model"):
            PACKAGE.validate_model_tree(mac_tree, "windows-x64")
        windows_tree = self._prepare("windows-x64")
        PACKAGE.validate_model_tree(windows_tree, "windows-x64")
        with self.assertRaisesRegex(ValueError, "macos-arm64 package is missing Core ML model"):
            PACKAGE.validate_model_tree(windows_tree, "macos-arm64")
        # 已裁成 Windows 形态的目录不能再当作 Mac 包的来源。
        with self.assertRaisesRegex(ValueError, "macos-arm64 package is missing Core ML model"):
            PACKAGE.prepare_model_tree(windows_tree, "macos-arm64", self.root / "mac-from-windows")

        self.manifest.pop("blind_rgb")
        (self.source / "blind_rgb.onnx").unlink()
        shutil.rmtree(self.source / "blind_rgb.mlmodelc", ignore_errors=True)
        (self.source / "manifest.json").write_text(json.dumps(self.manifest, separators=(",", ":")) + "\n")
        for platform in PACKAGE.PLATFORMS:
            with self.subTest(platform=platform):
                with self.assertRaisesRegex(ValueError, f"{platform} package is missing blind_rgb.onnx"):
                    PACKAGE.prepare_model_tree(self.source, platform, self.root / f"no-blind-{platform}")

    def test_rejects_gnu_long_name_and_pax_header(self) -> None:
        long_name = "a" * 120 + "/f"
        cases = (
            (
                "GNU long-name header",
                _write_tar(
                    [
                        {"name": "manifest.json", "kind": "file", "data": b"{}"},
                        {"name": long_name, "kind": "file", "data": b"x"},
                    ],
                    tar_format=tarfile.GNU_FORMAT,
                ),
                [_entry("manifest.json", b"{}"), _entry(long_name, b"x")],
            ),
            (
                "PAX header",
                _write_tar(
                    [
                        {"name": "manifest.json", "kind": "file", "data": b"{}"},
                        {"name": "note.txt", "kind": "file", "data": b"x", "pax_headers": {"comment": "note"}},
                    ],
                    tar_format=tarfile.PAX_FORMAT,
                ),
                [_entry("manifest.json", b"{}"), _entry("note.txt", b"x")],
            ),
        )
        for label, compressed, entries in cases:
            with self.subTest(case=label):
                archive, description = _matching_description(self.root, compressed, entries)
                with self.assertRaisesRegex(ValueError, "extended metadata|canonical builder serialization"):
                    PACKAGE.verify_model_archive(archive, description)

    def test_rejects_trailing_slash_aliases_and_nonzero_padding(self) -> None:
        raw = bytearray(gzip.decompress(_write_tar([
            {"name": "empty", "kind": "directory"},
            {"name": "manifest.json", "kind": "file", "data": b"{}"},
        ])))
        name = b"empty/"
        offset = raw.find(name)
        self.assertGreaterEqual(offset, 0)
        header_offset = offset
        raw[header_offset:header_offset + 100] = b"empty///" + bytes(92)
        header = bytearray(raw[header_offset:header_offset + 512])
        _rechecksum_header(header)
        raw[header_offset:header_offset + 512] = header
        archive, description = _matching_description(
            self.root,
            _gzip_tar(bytes(raw)),
            [_entry("manifest.json", b"{}"), _entry("empty", b"", kind="directory")],
        )
        with self.assertRaisesRegex(ValueError, "canonical builder serialization"):
            PACKAGE.verify_model_archive(archive, description)

        alias_specs = [
            {"name": "alias", "kind": "file", "data": b"", "type": tarfile.AREGTYPE},
            {"name": "manifest.json", "kind": "file", "data": b"{}"},
        ]
        archive, description = self._crafted(alias_specs)
        with self.assertRaisesRegex(ValueError, "canonical builder serialization"):
            PACKAGE.verify_model_archive(archive, description)

        raw_padding = bytearray(gzip.decompress(_write_tar([{"name": "manifest.json", "kind": "file", "data": b"{}"}])))
        raw_padding[514] = 1
        archive, description = _matching_description(
            self.root,
            _gzip_tar(bytes(raw_padding)),
            [_entry("manifest.json", b"{}")],
        )
        with self.assertRaisesRegex(ValueError, "canonical builder serialization"):
            PACKAGE.verify_model_archive(archive, description)

    def test_rejects_paths_outside_ascii_policy(self) -> None:
        for bad_path in ("caf\u00e9.txt", "dir/C:stream"):
            with self.subTest(path=bad_path):
                specs = [
                    {"name": "manifest.json", "kind": "file", "data": b"{}"},
                    {"name": bad_path, "kind": "file", "data": b"x"},
                ]
                safe_entries = [_entry("manifest.json", b"{}"), _entry("safe.txt", b"x")]
                archive, description = self._crafted(specs, safe_entries)
                with self.assertRaisesRegex(ValueError, "Unsafe relative path in archive member"):
                    PACKAGE.verify_model_archive(archive, description)

    def test_rejects_links_and_special_members(self) -> None:
        cases = (
            ("symbolic link", {"name": "link", "kind": "symlink"}, "link member"),
            ("hard link", {"name": "link", "kind": "hardlink"}, "link member"),
            ("FIFO", {"name": "pipe", "kind": "fifo"}, "canonical builder serialization"),
            ("character device", {"name": "device", "kind": "char-device"}, "canonical builder serialization"),
        )
        for label, invalid, error in cases:
            with self.subTest(member=label):
                specs = [{"name": "manifest.json", "kind": "file", "data": b"{}"}, invalid]
                entries = [_entry("manifest.json", b"{}"), _entry(invalid["name"], b"")]
                archive, description = self._crafted(specs, entries)
                with self.assertRaisesRegex(ValueError, error):
                    PACKAGE.verify_model_archive(archive, description)

    def test_streaming_size_manifest_total_and_member_count_limits(self) -> None:
        specs = [{"name": "manifest.json", "kind": "file", "data": b"{}"}]
        archive, description = self._crafted(specs)
        readers = []
        reader_type = PACKAGE._SingleGzipReader

        class TrackingReader(reader_type):
            def __init__(self, *args):
                super().__init__(*args)
                readers.append(self)

        with mock.patch.object(PACKAGE, "MAX_FILE_BYTES", 1):
            with mock.patch.object(PACKAGE, "_SingleGzipReader", TrackingReader):
                with self.assertRaisesRegex(ValueError, "Archive member exceeds 1 bytes: manifest.json"):
                    PACKAGE.verify_model_archive(archive, description)
        self.assertEqual(readers[0].output_bytes, 512, "the oversized payload was not decompressed")
        with mock.patch.object(PACKAGE, "MAX_MANIFEST_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "Archive manifest exceeds 1 bytes"):
                PACKAGE.verify_model_archive(archive, description)

        archive, description = self._crafted(
            [{"name": "manifest.json", "kind": "file", "data": b"{}"}, {"name": "x", "kind": "file", "data": b"y"}]
        )
        lower_total = copy.deepcopy(description)
        lower_total["unpackedBytes"] -= 1
        with self.assertRaisesRegex(ValueError, "described unpacked byte limit"):
            PACKAGE.verify_model_archive(archive, lower_total)
        fewer_entries = copy.deepcopy(description)
        fewer_entries["entries"] = fewer_entries["entries"][:1]
        with self.assertRaisesRegex(ValueError, "more members than the description"):
            PACKAGE.verify_model_archive(archive, fewer_entries)

    def test_main_build_then_verify_and_tampered_verify_returns_nonzero(self) -> None:
        output = self.root / "cli-output"
        stdout, build_stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(build_stderr):
            self.assertEqual(
                PACKAGE.main(
                    ["build", "--source", str(self.source), "--output-dir", str(output), "--platform", "windows-x64"]
                ),
                0,
            )
        self.assertIn("dualdn_probe semantic validation not run", build_stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue())[0]["platform"], "windows-x64")
        archive = next(output.glob("*.tar.gz"))
        description = Path(f"{archive}.json")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(PACKAGE.main(["verify", "--archive", str(archive), "--description", str(description)]), 0)

        damaged = bytearray(archive.read_bytes())
        damaged[len(damaged) // 2] ^= 1
        archive.write_bytes(damaged)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(PACKAGE.main(["verify", "--archive", str(archive), "--description", str(description)]), 2)
        self.assertIn("Archive SHA-256 mismatch", stderr.getvalue())

    @unittest.skipIf(os.name == "nt", "temporary executable fixture uses a POSIX shebang")
    def test_optional_probe_runs_for_each_tree_and_failure_stops_build(self) -> None:
        probe = self.root / "dualdn_probe"
        log = self.root / "probe.log"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "assert sys.argv[1] == '--validate'\n"
            "with open(os.environ['PROBE_LOG'], 'a') as f: f.write(sys.argv[2] + '\\n')\n",
            encoding="utf-8",
        )
        probe.chmod(0o755)
        with mock.patch.dict(os.environ, {"PROBE_LOG": str(log)}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(
                PACKAGE.main([
                    "build", "--source", str(self.source), "--output-dir", str(self.root / "probe-out"),
                    "--probe", str(probe),
                ]),
                0,
            )
        self.assertEqual(len(log.read_text().splitlines()), 2)

        probe.write_text("#!/usr/bin/env python3\nraise SystemExit(7)\n", encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(
                PACKAGE.main([
                    "build", "--source", str(self.source), "--output-dir", str(self.root / "probe-fail"),
                    "--platform", "windows-x64", "--probe", str(probe),
                ]),
                2,
            )
        self.assertIn("dualdn_probe --validate failed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
