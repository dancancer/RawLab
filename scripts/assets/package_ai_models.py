#!/usr/bin/env python3
"""Build deterministic platform archives for DualDn model packages.

The archive description is trusted: it is built alongside the archive and ships inside the signed app.
The archive bytes are untrusted. Both native downloaders must mirror these rules:
1. Check archive size, then SHA-256, against the description before decompressing or parsing anything;
   stop immediately on either mismatch.
2. After that check, this builder verifies the content as a publish-time self-check and defence in depth.
3. Clients extract only described members as regular files and directories with safe permissions of
   their own, ignoring archive modes and owners, into a staging directory. Core package validation is
   the final gate.
"""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zlib


PREPARE_PATH = Path(__file__).with_name("prepare.py")
_PREPARE_SPEC = importlib.util.spec_from_file_location("rawlab_assets_prepare", PREPARE_PATH)
if _PREPARE_SPEC is None or _PREPARE_SPEC.loader is None:
    raise RuntimeError(f"Cannot load asset helpers from {PREPARE_PATH}")
_PREPARE = importlib.util.module_from_spec(_PREPARE_SPEC)
_PREPARE_SPEC.loader.exec_module(_PREPARE)

PLATFORMS = ("macos-arm64", "windows-x64")
LICENSE_FILES = ("DualDn-LICENSE.txt", "Restormer-LICENSE.txt")
# 平台包完整性是发布规则，不是核心协议：核心把 Core ML 和通用 RGB 模型当作可选项，
# 缺了它们的包能通过核心校验，却不能在对应平台上运行 AI 降噪。
ONNX_FILES = ("raw.onnx", "isp.onnx", "rgb.onnx", "blind_rgb.onnx")
COREML_BUNDLES = ("raw.mlmodelc", "rgb.mlmodelc", "blind_rgb.mlmodelc")
SOURCE_ONLY_TEST_TENSORS = frozenset("""
    blind_rgb-encoded_rgb.f32 blind_rgb-expected.f32 isp-camera_to_xyz.f32 isp-expected.f32
    isp-mosaic.f32 isp-wb.f32 raw-b.f32 raw-expected.f32 raw-k.f32 raw-packed_raw.f32
    rgb-expected.f32 rgb-noise_rgb.f32 rgb-skip_rgb.f32
""".split())
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_COREML_FILES = 64
MAX_MANIFEST_BYTES = 65536
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SAFE_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


def _sha256_file(path: Path) -> tuple[str, int]:
    return _PREPARE.sha256_file(path)


def _sha256_stream(stream) -> tuple[str, int]:
    digest, size = hashlib.sha256(), 0
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
        size += len(chunk)
    return digest.hexdigest(), size


def _validate_relative_path(value: str, *, context: str) -> None:
    if (not isinstance(value, str) or not value or _SAFE_PATH_RE.fullmatch(value) is None
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"Unsafe relative path in {context}: {value!r}")


def _read_manifest(root: Path) -> dict:
    path = root / "manifest.json"
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing required model file: manifest.json")
    size = path.stat().st_size
    if size > MAX_MANIFEST_BYTES:
        raise ValueError(f"DualDn manifest exceeds {MAX_MANIFEST_BYTES} bytes")
    data = path.read_bytes()
    try:
        manifest = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Invalid UTF-8 JSON in manifest.json: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ValueError("DualDn manifest must be a JSON object")
    return manifest


def _manifest_file_records(manifest: dict) -> dict[str, tuple[int, str]]:
    """Collect file records without interpreting model protocol fields."""
    records: dict[str, tuple[int, str]] = {}

    def add(path: object, record: dict, prefix: str = "") -> None:
        if not isinstance(path, str):
            raise ValueError("Invalid file path in model manifest")
        relative = f"{prefix}/{path}" if prefix else path
        _validate_relative_path(relative, context="model manifest")
        size, digest = record.get("bytes"), record.get("sha256")
        if type(size) is not int or size < 0 or size > MAX_FILE_BYTES:
            raise ValueError(f"Invalid file size in model manifest: {relative}")
        if not isinstance(digest, str) or _SHA256_RE.fullmatch(digest) is None:
            raise ValueError(f"Invalid SHA-256 in model manifest: {relative}")
        if relative in records:
            raise ValueError(f"Duplicate model manifest file: {relative}")
        records[relative] = (size, digest)

    def visit(value: object) -> None:
        if isinstance(value, dict):
            if "file" in value:
                add(value["file"], value)
            if "files" in value:
                directory = value.get("directory")
                entries = value["files"]
                if not isinstance(directory, str) or not isinstance(entries, list):
                    raise ValueError("Invalid file list in model manifest")
                if len(entries) > MAX_COREML_FILES:
                    raise ValueError(f"Too many model files in {directory}")
                for entry in entries:
                    if not isinstance(entry, dict):
                        raise ValueError(f"Invalid file entry in {directory}")
                    add(entry.get("path"), entry, directory)
            for key, child in value.items():
                if key != "files" and isinstance(child, (dict, list)):
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(manifest)
    if "manifest.json" in records:
        raise ValueError("manifest.json cannot list itself as a model file")
    return records


def _record_casefold_path(folded: dict[str, str], relative: str) -> None:
    key = relative.casefold()
    previous = folded.get(key)
    if previous is not None:
        reason = "Duplicate model path" if previous == relative else f"Case-insensitive model path collision: {previous} and"
        raise ValueError(f"{reason} {relative}")
    folded[key] = relative


def _walk_model_tree(root: Path) -> tuple[dict[str, Path], set[str]]:
    if root.is_symlink():
        raise ValueError(f"Refusing symbolic-link model directory: {root}")
    if not root.is_dir():
        raise ValueError(f"Model directory does not exist: {root}")
    files: dict[str, Path] = {}
    directories: set[str] = set()
    folded: dict[str, str] = {}

    def on_error(error: OSError) -> None:
        raise error

    def add_path(path: Path, is_directory: bool) -> None:
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise ValueError(f"Refusing symbolic link in model directory: {relative}")
        if is_directory and not stat.S_ISDIR(mode):
            raise ValueError(f"Refusing special file in model directory: {relative}")
        if not is_directory and not stat.S_ISREG(mode):
            raise ValueError(f"Refusing special file in model directory: {relative}")
        _validate_relative_path(relative, context="model directory")
        _record_casefold_path(folded, relative)
        if is_directory:
            directories.add(relative)
        else:
            files[relative] = path

    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False, onerror=on_error):
        current_path = Path(current)
        dirnames.sort()
        filenames.sort()
        for name in dirnames:
            add_path(current_path / name, True)
        for name in filenames:
            add_path(current_path / name, False)
    return files, directories


def _check_platform_files(platform: str, files) -> None:
    present = set(files)
    for name in ONNX_FILES:
        if name not in present:
            raise ValueError(f"{platform} package is missing {name}")
    bundles = {path.split("/", 1)[0] for path in present if "/" in path and path.split("/", 1)[0].endswith(".mlmodelc")}
    if platform == "macos-arm64":
        for name in COREML_BUNDLES:
            if name not in bundles:
                raise ValueError(f"{platform} package is missing Core ML model {name}")
    elif bundles:
        raise ValueError(f"{platform} package must not contain Core ML model {sorted(bundles)[0]}")


def validate_model_tree(root: Path | str, platform: str, *, source_package: bool = False) -> dict:
    """Check the manifest file set, file records, licences, and plain-file tree shape.

    Empty directories are ignored; preparation creates only parents needed by listed files, so empty
    directories inside Core ML bundles do not enter the platform archive.
    """
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported platform {platform!r}; expected one of {', '.join(PLATFORMS)}")
    root_path = Path(root)
    files, _ = _walk_model_tree(root_path)
    manifest = _read_manifest(root_path)
    records = _manifest_file_records(manifest)
    expected = {"manifest.json", *records, *LICENSE_FILES}
    allowed_source_extras = SOURCE_ONLY_TEST_TENSORS if source_package else frozenset()
    missing = sorted(expected - set(files))
    if missing:
        raise ValueError(f"Missing required model file: {missing[0]}")
    unexpected = sorted(set(files) - expected - allowed_source_extras)
    if unexpected:
        raise ValueError(f"File is not listed in the model manifest: {unexpected[0]}")
    for relative, (expected_size, expected_sha) in records.items():
        actual_sha, actual_size = _sha256_file(files[relative])
        if actual_size != expected_size or actual_sha != expected_sha:
            raise ValueError(
                f"Manifest digest mismatch for {relative}: expected sha256={expected_sha} bytes={expected_size}, "
                f"got sha256={actual_sha} bytes={actual_size}"
            )
    for relative in LICENSE_FILES:
        if files[relative].stat().st_size == 0:
            raise ValueError(f"Required licence is empty: {relative}")
    if not source_package:
        _check_platform_files(platform, files)
    return manifest


def strip_coreml_fields(manifest: dict) -> dict:
    """Apply the Windows manifest transformation used by the existing build script."""
    result = copy.deepcopy(manifest)
    result.pop("coreml", None)
    blind = result.get("blind_rgb")
    if isinstance(blind, dict):
        blind.pop("coreml", None)
    return result


def _path_is_inside(path: Path, directory: Path) -> bool:
    candidate = path.resolve(strict=False)
    parent = directory.resolve(strict=False)
    return candidate == parent or parent in candidate.parents


def prepare_model_tree(source: Path | str, platform: str, destination: Path | str) -> Path:
    """Copy only listed platform files to a new tree; never mutate source."""
    source_path = Path(source)
    if source_path.is_symlink():
        raise ValueError(f"Refusing symbolic-link model directory: {source_path}")
    source_path = source_path.resolve()
    destination_path = Path(destination)
    if _path_is_inside(destination_path, source_path):
        raise ValueError(f"Output path must be outside source model directory: {destination_path}")
    manifest = validate_model_tree(source_path, platform, source_package=True)
    all_source_files, _ = _walk_model_tree(source_path)
    output_manifest = strip_coreml_fields(manifest) if platform == "windows-x64" else manifest
    expected_files = {"manifest.json", *(_manifest_file_records(output_manifest)), *LICENSE_FILES}
    _check_platform_files(platform, expected_files)
    if destination_path.exists() or destination_path.is_symlink():
        raise ValueError(f"Destination already exists: {destination_path}")
    try:
        destination_path.mkdir(parents=True)
        for relative in sorted(expected_files):
            destination_file = destination_path / relative
            destination_file.parent.mkdir(parents=True, exist_ok=True)
            if relative == "manifest.json" and platform == "windows-x64":
                destination_file.write_text(
                    json.dumps(output_manifest, ensure_ascii=False, separators=(",", ":")) + "\n",
                    encoding="utf-8",
                )
            else:
                shutil.copyfile(all_source_files[relative], destination_file)
    except Exception:
        shutil.rmtree(destination_path, ignore_errors=True)
        raise
    return destination_path


def _add_canonical_member(tar, relative: str, kind: str, size: int, source) -> None:
    info = tarfile.TarInfo(relative)
    info.mtime = info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.pax_headers = {}
    if kind == "directory":
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.size = 0
        tar.addfile(info)
        return
    info.type = tarfile.REGTYPE
    info.mode = 0o644
    info.size = size
    if isinstance(source, Path):
        with source.open("rb") as stream:
            tar.addfile(info, stream)
    else:
        if source is None:
            raise ValueError(f"Missing source stream for archive member: {relative}")
        tar.addfile(info, source)


def _write_canonical_tar(tar, members) -> None:
    for relative, kind, size, source in members:
        _add_canonical_member(tar, relative, kind, size, source)


def create_model_archive(tree: Path | str, archive_path: Path | str) -> Path:
    """Write sorted USTAR entries with fixed metadata and a fixed gzip header."""
    tree_path = Path(tree)
    archive = Path(archive_path)
    if _path_is_inside(archive, tree_path):
        raise ValueError(f"Archive output must be outside model tree: {archive}")
    files, directories = _walk_model_tree(tree_path)
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{archive.name}.", suffix=".tmp", dir=archive.parent, delete=False
        ) as raw_output:
            temporary = Path(raw_output.name)
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, compresslevel=9, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                    members = [(path, "directory", 0, None) for path in directories]
                    members.extend((relative, "file", path.stat().st_size, path) for relative, path in files.items())
                    members.sort(key=lambda member: member[0])
                    _write_canonical_tar(tar, members)
        os.replace(temporary, archive)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return archive


class _SingleGzipReader:
    """Streaming reader that checks one gzip member and its trailer."""

    def __init__(self, source, max_output_bytes: int | None) -> None:
        self.source, self.max_output_bytes = source, max_output_bytes
        self.decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        self.compressed, self.output_bytes = b"", 0

    def _finish(self) -> bytes:
        trailing = self.decompressor.unused_data
        if len(trailing) < 2:
            trailing += self.source.read(2 - len(trailing))
        if trailing:
            if trailing.startswith(b"\x1f\x8b"):
                raise ValueError("Multiple gzip members are not allowed")
            raise ValueError("Trailing bytes after gzip member")
        return b""

    def read(self, size: int = -1) -> bytes:
        if size == 0:
            return b""
        if size < 0:
            return b"".join(iter(lambda: self.read(65536), b""))
        result = bytearray()
        while len(result) < size:
            if self.decompressor.eof:
                break
            if not self.compressed:
                self.compressed = self.source.read(65536)
                if not self.compressed:
                    raise ValueError("Truncated gzip stream")
            limit = size - len(result)
            if self.max_output_bytes is not None:
                limit = min(limit, self.max_output_bytes - self.output_bytes + 1)
            try:
                chunk = self.decompressor.decompress(self.compressed, limit)
            except zlib.error as exc:
                raise ValueError(f"Invalid gzip stream: {exc}") from exc
            self.compressed = self.decompressor.unconsumed_tail
            if self.max_output_bytes is not None and self.output_bytes + len(chunk) > self.max_output_bytes:
                raise ValueError("Decompressed tar exceeds the described member limits")
            result.extend(chunk)
            self.output_bytes += len(chunk)
        if not result and self.decompressor.eof:
            return self._finish()
        return bytes(result)


def _canonical_tar_bytes(entries: list) -> int:
    """Exact length of the builder's tar for these entries.

    One 512-byte header per member, file data padded to 512, then two zero blocks, the whole padded
    to the tar record size. An estimate is not enough here: tarfile pads after the end blocks, so
    the padding can exceed one record minus the end blocks.
    """
    body = 0
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("kind") not in ("file", "directory"):
            raise ValueError("Description has an invalid member entry")
        size = entry.get("bytes")
        if type(size) is not int or size < 0:
            raise ValueError("Description has an invalid member size")
        body += 512 + (-(-size // 512) * 512 if entry["kind"] == "file" else 0)
    return -(-(body + 1024) // tarfile.RECORDSIZE) * tarfile.RECORDSIZE


class _TarCompareWriter:
    def __init__(self, reader: _SingleGzipReader) -> None:
        self.reader, self.expected = reader, bytearray()
        self.bytes_written, self.mismatch = 0, False

    def expect(self, data: bytes) -> None:
        self.expected.extend(data)

    def write(self, data: bytes) -> int:
        count = len(data)
        actual = bytes(self.expected[:count])
        del self.expected[:count]
        if len(actual) < count:
            actual += self.reader.read(count - len(actual))
        self.mismatch |= actual != data
        self.bytes_written += count
        return count

    def tell(self) -> int:
        return self.bytes_written


class _ArchiveMemberStream:
    def __init__(self, reader: _SingleGzipReader, comparator: _TarCompareWriter, size: int) -> None:
        self.reader, self.comparator = reader, comparator
        self.remaining, self.digest = size, hashlib.sha256()

    def read(self, size: int = -1) -> bytes:
        if self.remaining == 0:
            return b""
        chunk = self.reader.read(self.remaining if size < 0 else min(size, self.remaining))
        self.remaining -= len(chunk)
        self.digest.update(chunk)
        self.comparator.expect(chunk)
        return chunk


def _archive_inventory(
    archive_path: Path,
    *,
    expected_unpacked_bytes: int | None = None,
    expected_member_count: int | None = None,
    max_tar_bytes: int | None = None,
) -> tuple[list[dict], int, str]:
    entries: list[dict] = []
    folded: dict[str, str] = {}
    kinds: dict[str, str] = {}
    manifest_sha, unpacked_bytes = None, 0
    try:
        with archive_path.open("rb") as compressed:
            reader = _SingleGzipReader(compressed, max_tar_bytes)
            comparator = _TarCompareWriter(reader)

            def members():
                nonlocal manifest_sha, unpacked_bytes
                count, previous = 0, None
                while True:
                    header = reader.read(512)
                    if len(header) != 512:
                        raise ValueError("Truncated tar header")
                    if header == bytes(512):
                        comparator.expect(header)
                        return
                    member = tarfile.TarInfo.frombuf(header, "utf-8", "surrogateescape")
                    count += 1
                    if expected_member_count is not None and count > expected_member_count:
                        raise ValueError("Archive has more members than the description")
                    if member.issym() or member.islnk():
                        raise ValueError(f"Refusing link member in archive: {member.name}")
                    if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
                        raise ValueError("Tar stream is not the canonical builder serialization")
                    if member.linkname:
                        raise ValueError(f"Refusing link target in archive member: {member.name}")
                    relative = member.name
                    _validate_relative_path(relative, context="archive member")
                    _record_casefold_path(folded, relative)
                    if previous is not None and relative < previous:
                        raise ValueError("Tar stream is not the canonical builder serialization")
                    previous = relative
                    comparator.expect(header)
                    if member.isdir():
                        if member.size != 0:
                            raise ValueError(f"Directory archive member has data: {relative}")
                        kinds[relative] = "directory"
                        entries.append({"path": relative, "kind": "directory", "bytes": 0})
                        yield relative, "directory", 0, None
                        continue
                    if member.size < 0:
                        raise ValueError(f"Invalid archive member size: {relative}")
                    if member.size > MAX_FILE_BYTES:
                        raise ValueError(f"Archive member exceeds {MAX_FILE_BYTES} bytes: {relative}")
                    if relative == "manifest.json" and member.size > MAX_MANIFEST_BYTES:
                        raise ValueError(f"Archive manifest exceeds {MAX_MANIFEST_BYTES} bytes")
                    if expected_unpacked_bytes is not None and unpacked_bytes + member.size > expected_unpacked_bytes:
                        raise ValueError("Archive exceeds the described unpacked byte limit")
                    stream = _ArchiveMemberStream(reader, comparator, member.size)
                    yield relative, "file", member.size, stream
                    if stream.remaining:
                        raise ValueError(f"Archive member size mismatch: {relative}")
                    sha = stream.digest.hexdigest()
                    if relative == "manifest.json":
                        manifest_sha = sha
                    kinds[relative] = "file"
                    entries.append({"path": relative, "kind": "file", "bytes": member.size, "sha256": sha})
                    unpacked_bytes += member.size

            canonical_tar = tarfile.open(fileobj=comparator, mode="w", format=tarfile.USTAR_FORMAT)
            try:
                _write_canonical_tar(canonical_tar, members())
            except BaseException:
                canonical_tar.closed = True
                raise
            canonical_tar.close()
            while reader.read(65536):
                comparator.mismatch = True
            for relative in kinds:
                parent = Path(relative).parent
                while str(parent) != ".":
                    parent_name = parent.as_posix()
                    if kinds.get(parent_name) == "file":
                        raise ValueError(f"Archive file is used as a directory: {parent_name}")
                    parent = parent.parent
            if manifest_sha is None:
                raise ValueError("Archive is missing root manifest.json")
            if comparator.mismatch or comparator.expected:
                raise ValueError("Tar stream is not the canonical builder serialization")
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise ValueError(f"Invalid tar.gz archive {archive_path}: {exc}") from exc
    entries.sort(key=lambda entry: entry["path"])
    return entries, unpacked_bytes, manifest_sha


def _archive_platform_and_digest_name(archive_path: Path) -> tuple[str, str]:
    match = re.fullmatch(r"rawlab-ai-(macos-arm64|windows-x64)-([0-9a-f]{12})\.tar\.gz", archive_path.name)
    if match is None:
        raise ValueError(f"Invalid AI model archive name: {archive_path.name}")
    return match.group(1), match.group(2)


def describe_model_archive(archive_path: Path | str, platform: str | None = None) -> dict:
    archive = Path(archive_path)
    archive_sha, archive_bytes = _sha256_file(archive)
    named_platform, named_prefix = _archive_platform_and_digest_name(archive)
    if platform is not None and platform != named_platform:
        raise ValueError(f"Archive platform name mismatch: expected {platform}, got {named_platform}")
    if archive_sha[:12] != named_prefix:
        raise ValueError(f"Archive filename does not match SHA-256: {archive.name}")
    entries, unpacked_bytes, manifest_sha = _archive_inventory(archive)
    return {
        "schemaVersion": 1,
        "platform": named_platform,
        "archiveName": archive.name,
        "archiveSha256": archive_sha,
        "archiveBytes": archive_bytes,
        "manifestSha256": manifest_sha,
        "unpackedBytes": unpacked_bytes,
        "entries": entries,
    }


def verify_model_archive(archive_path: Path | str, description: dict) -> None:
    """Check archive bytes first, then enforce its described contents and canonical encoding."""
    archive = Path(archive_path)
    if not isinstance(description, dict):
        raise ValueError("Unsupported AI model archive description")
    expected_bytes = description.get("archiveBytes")
    if type(expected_bytes) is not int or expected_bytes < 0:
        raise ValueError("Description has an invalid archive size")

    with archive.open("rb") as stream:
        actual_bytes = os.fstat(stream.fileno()).st_size
        if actual_bytes != expected_bytes:
            raise ValueError(f"Archive size mismatch: expected {expected_bytes}, got {actual_bytes}")
        expected_sha = description.get("archiveSha256")
        if not isinstance(expected_sha, str) or _SHA256_RE.fullmatch(expected_sha) is None:
            raise ValueError("Description has an invalid archive SHA-256")
        actual_sha, hashed_bytes = _sha256_stream(stream)
    if hashed_bytes != actual_bytes:
        raise ValueError(f"Archive size mismatch: expected {actual_bytes}, got {hashed_bytes}")
    if actual_sha != expected_sha:
        raise ValueError(f"Archive SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")

    if type(description.get("schemaVersion")) is not int or description["schemaVersion"] != 1:
        raise ValueError("Unsupported AI model archive description")
    platform = description.get("platform")
    if platform not in PLATFORMS:
        raise ValueError("Description has an unsupported platform")
    if description.get("archiveName") != archive.name:
        raise ValueError(f"Archive name mismatch: expected {description.get('archiveName')!r}, got {archive.name!r}")
    named_platform, named_prefix = _archive_platform_and_digest_name(archive)
    if named_platform != platform or named_prefix != actual_sha[:12]:
        raise ValueError("Archive filename does not match its platform and SHA-256")
    manifest_sha = description.get("manifestSha256")
    if not isinstance(manifest_sha, str) or _SHA256_RE.fullmatch(manifest_sha) is None:
        raise ValueError("Description has an invalid manifest SHA-256")
    expected_unpacked = description.get("unpackedBytes")
    if type(expected_unpacked) is not int or expected_unpacked < 0:
        raise ValueError("Description has an invalid unpacked size")
    expected_entries = description.get("entries")
    if not isinstance(expected_entries, list):
        raise ValueError("Description has no member list")

    actual_entries, unpacked, actual_manifest_sha = _archive_inventory(
        archive,
        expected_unpacked_bytes=expected_unpacked,
        expected_member_count=len(expected_entries),
        max_tar_bytes=_canonical_tar_bytes(expected_entries),
    )
    if actual_manifest_sha != manifest_sha:
        raise ValueError(f"Manifest SHA-256 mismatch: expected {manifest_sha}, got {actual_manifest_sha}")
    if actual_entries != expected_entries:
        raise ValueError("Archive members do not match the description")
    if unpacked != expected_unpacked:
        raise ValueError(f"Unpacked size mismatch: expected {expected_unpacked}, got {unpacked}")


def _write_description(path: Path, description: dict) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(description, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _build_one(source: Path, platform: str, output_dir: Path, probe: str | None) -> dict:
    with tempfile.TemporaryDirectory(prefix=f".rawlab-ai-{platform}-", dir=output_dir) as temporary_dir:
        temporary_root = Path(temporary_dir)
        tree = prepare_model_tree(source, platform, temporary_root / "tree")
        if probe is not None:
            result = subprocess.run([probe, "--validate", str(tree)], check=False)
            if result.returncode != 0:
                raise ValueError(f"dualdn_probe --validate failed for {platform} with exit code {result.returncode}")
        staged_archive = create_model_archive(tree, temporary_root / "staged.tar.gz")
        staged_digest, staged_size = _sha256_file(staged_archive)
        final_archive = output_dir / f"rawlab-ai-{platform}-{staged_digest[:12]}.tar.gz"
        if final_archive.exists():
            existing_digest, existing_size = _sha256_file(final_archive)
            if (existing_digest, existing_size) != (staged_digest, staged_size):
                raise ValueError(f"Hash-named archive collision at {final_archive}")
        else:
            os.replace(staged_archive, final_archive)
        description = describe_model_archive(final_archive, platform)
        _write_description(output_dir / f"{final_archive.name}.json", description)
        return description


def _command_build(args: argparse.Namespace) -> int:
    source = Path(args.source)
    if source.is_symlink():
        raise ValueError(f"Refusing symbolic-link model directory: {source}")
    source = source.resolve()
    output_dir = Path(args.output_dir)
    if _path_is_inside(output_dir, source):
        raise ValueError(f"Output path must be outside source model directory: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    platforms = PLATFORMS if args.platform == "all" else (args.platform,)
    if args.probe is None:
        print("dualdn_probe semantic validation not run (--probe not supplied)", file=sys.stderr)
    descriptions = [_build_one(source, platform, output_dir, args.probe) for platform in platforms]
    print(json.dumps(descriptions, ensure_ascii=False, indent=2))
    return 0


def _command_verify(args: argparse.Namespace) -> int:
    archive = Path(args.archive)
    description_path = Path(args.description)
    try:
        description = json.loads(description_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read description {description_path}: {exc}") from exc
    verify_model_archive(archive, description)
    print(f"verified {archive.name}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build deterministic Mac arm64 and Windows x64 DualDn model archives, or verify an archive."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build", help="build platform archives from a model package")
    build_parser.add_argument("--source", required=True, help="complete DualDn model directory")
    build_parser.add_argument("--output-dir", required=True, help="directory for archives and JSON descriptions")
    build_parser.add_argument(
        "--platform", choices=(*PLATFORMS, "all"), default="all", help="platform to build (default: all)"
    )
    build_parser.add_argument("--probe", help="optional dualdn_probe executable used to validate each prepared tree")
    build_parser.set_defaults(handler=_command_build)
    verify_parser = subparsers.add_parser("verify", help="verify an archive against its JSON description")
    verify_parser.add_argument("--archive", required=True, help="archive to verify")
    verify_parser.add_argument("--description", required=True, help="JSON description produced by build")
    verify_parser.set_defaults(handler=_command_verify)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (OSError, ValueError, tarfile.TarError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
