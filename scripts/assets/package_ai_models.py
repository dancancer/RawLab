#!/usr/bin/env python3
"""Build and verify deterministic platform archives for a validated DualDn model package."""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from functools import lru_cache


REPO_ROOT = Path(__file__).resolve().parents[2]
MODEL_PACKAGE_HEADER = REPO_ROOT / "lutools" / "src" / "ai" / "model_package.h"
PREPARE_PATH = Path(__file__).with_name("prepare.py")
_PREPARE_SPEC = importlib.util.spec_from_file_location("rawlab_assets_prepare", PREPARE_PATH)
if _PREPARE_SPEC is None or _PREPARE_SPEC.loader is None:
    raise RuntimeError(f"Cannot load asset helpers from {PREPARE_PATH}")
_PREPARE = importlib.util.module_from_spec(_PREPARE_SPEC)
_PREPARE_SPEC.loader.exec_module(_PREPARE)

PLATFORMS = ("macos-arm64", "windows-x64")
BASE_FILES = (
    "raw.onnx",
    "isp.onnx",
    "rgb.onnx",
    "blind_rgb.onnx",
    "DualDn-LICENSE.txt",
    "Restormer-LICENSE.txt",
)
SOURCE_ONLY_TEST_TENSORS = frozenset(
    {
        "blind_rgb-encoded_rgb.f32",
        "blind_rgb-expected.f32",
        "isp-camera_to_xyz.f32",
        "isp-expected.f32",
        "isp-mosaic.f32",
        "isp-wb.f32",
        "raw-b.f32",
        "raw-expected.f32",
        "raw-k.f32",
        "raw-packed_raw.f32",
        "rgb-expected.f32",
        "rgb-noise_rgb.f32",
        "rgb-skip_rgb.f32",
    }
)
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_COREML_FILES = 64
MAX_MANIFEST_BYTES = 65536
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


@lru_cache(maxsize=1)
def _model_package_constants() -> dict[str, str]:
    source = MODEL_PACKAGE_HEADER.read_text(encoding="utf-8")
    names = (
        "dualdnSourceRevision",
        "dualdnWeightsSHA256",
        "restormerSourceRevision",
        "restormerWeightsSHA256",
        "restormerLicenseSHA256",
    )
    constants: dict[str, str] = {}
    for name in names:
        match = re.search(rf"\b{name}\s*=\s*\"([0-9a-f]+)\"", source)
        if match is None:
            raise ValueError(f"Missing {name} in {MODEL_PACKAGE_HEADER}")
        constants[name] = match.group(1)
    return constants


def _sha256_file(path: Path) -> tuple[str, int]:
    return _PREPARE.sha256_file(path)


def _validate_relative_path(value: str, *, context: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not value or "\\" in value or value.startswith("/"):
        raise ValueError(f"Unsafe relative path in {context}: {value!r}")
    if re.match(r"^[A-Za-z]:", value):
        raise ValueError(f"Drive-qualified path in {context}: {value!r}")
    parts = tuple(value.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Unsafe relative path in {context}: {value!r}")
    if PurePosixPath(value).is_absolute():
        raise ValueError(f"Absolute path in {context}: {value!r}")
    return parts


def _resolve_inside(root: Path, relative: str) -> Path:
    parts = _validate_relative_path(relative, context="model manifest")
    return root.joinpath(*parts)


def _check_digest_record(root: Path, relative: str, record: dict, *, context: str) -> tuple[int, str]:
    if not isinstance(record, dict):
        raise ValueError(f"Invalid file record in {context}: {relative}")
    size = record.get("bytes")
    expected_sha = record.get("sha256")
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0 or size > MAX_FILE_BYTES:
        raise ValueError(f"Invalid file size in {context}: {relative}")
    if not isinstance(expected_sha, str) or _SHA256_RE.fullmatch(expected_sha) is None:
        raise ValueError(f"Invalid SHA-256 in {context}: {relative}")
    path = _resolve_inside(root, relative)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Missing required model file: {relative}")
    actual_sha, actual_bytes = _sha256_file(path)
    if actual_bytes != size or actual_sha != expected_sha:
        raise ValueError(
            f"Manifest digest mismatch for {relative}: expected sha256={expected_sha} bytes={size}, "
            f"got sha256={actual_sha} bytes={actual_bytes}"
        )
    return size, actual_sha


def _read_manifest(root: Path) -> tuple[dict, bytes]:
    path = root / "manifest.json"
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing required model file: manifest.json")
    data = path.read_bytes()
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError(f"DualDn manifest exceeds {MAX_MANIFEST_BYTES} bytes")
    try:
        manifest = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Invalid UTF-8 JSON in manifest.json: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ValueError("DualDn manifest must be a JSON object")
    return manifest, data


def _validate_protocol(manifest: dict) -> None:
    constants = _model_package_constants()
    expected = {
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
        "isp": {
            "demosaic": "AHD",
            "gamma": "Rec709",
            "reference": "D65",
            "alpha": 0,
            "bgu": False,
        },
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"Unsupported DualDn model protocol field: {key}")


def _validate_graphs(root: Path, manifest: dict) -> set[str]:
    graphs = manifest.get("graphs")
    if not isinstance(graphs, dict) or set(graphs) != {"raw", "isp", "rgb"}:
        raise ValueError("DualDn manifest graphs must contain exactly raw, isp, and rgb")
    files: set[str] = set()
    for name in ("raw", "isp", "rgb"):
        relative = f"{name}.onnx"
        graph = graphs[name]
        if not isinstance(graph, dict) or graph.get("file") != relative:
            raise ValueError(f"Invalid DualDn graph filename: {relative}")
        _check_digest_record(root, relative, graph, context=f"graphs.{name}")
        files.add(relative)
    return files


def _validate_blind_rgb(root: Path, manifest: dict) -> set[str]:
    constants = _model_package_constants()
    graph = manifest.get("blind_rgb")
    if not isinstance(graph, dict):
        raise ValueError("DualDn manifest must contain blind_rgb")
    expected = {
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
        "license_file": "Restormer-LICENSE.txt",
        "license_sha256": constants["restormerLicenseSHA256"],
    }
    for key, value in expected.items():
        if graph.get(key) != value:
            raise ValueError(f"Unsupported blind_rgb manifest field: {key}")
    _check_digest_record(root, "blind_rgb.onnx", graph, context="blind_rgb")
    license_path = "Restormer-LICENSE.txt"
    license_file = root / license_path
    if license_file.is_symlink() or not license_file.is_file():
        raise ValueError(f"Missing required model file: {license_path}")
    license_sha, license_bytes = _sha256_file(license_file)
    if license_sha != constants["restormerLicenseSHA256"] or license_bytes == 0:
        raise ValueError(f"Restormer license SHA-256 mismatch: {license_path}")
    return {"blind_rgb.onnx", license_path}


def _coreml_files(
    root: Path, record: dict, directory: str, *, context: str, require_precision: bool = False
) -> set[str]:
    if (
        not isinstance(record, dict)
        or record.get("directory") != directory
        or (require_precision and record.get("precision") != "float32")
    ):
        raise ValueError(f"Invalid Core ML model record: {context}")
    entries = record.get("files")
    if not isinstance(entries, list) or not entries or len(entries) > MAX_COREML_FILES:
        raise ValueError(f"Invalid Core ML file list: {context}")
    paths: set[str] = set()
    folded: set[str] = set()
    total = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f"Invalid Core ML file entry: {context}")
        relative = entry.get("path")
        _validate_relative_path(relative, context=context)
        folded_path = relative.casefold()
        if relative in paths or folded_path in folded:
            raise ValueError(f"Duplicate Core ML resource path in {context}: {relative}")
        paths.add(relative)
        folded.add(folded_path)
        size, _ = _check_digest_record(root / directory, relative, entry, context=context)
        total += size
        if total > MAX_FILE_BYTES:
            raise ValueError(f"Core ML resources exceed {MAX_FILE_BYTES} bytes: {context}")
    return {f"{directory}/{relative}" for relative in paths}


def _validate_coreml(root: Path, manifest: dict, *, required: bool) -> set[str]:
    if "coreml" not in manifest:
        if required:
            raise ValueError("Mac model package is missing manifest coreml resources")
        return set()
    coreml = manifest["coreml"]
    if not required:
        raise ValueError("Windows manifest must not contain top-level coreml resources")
    if not isinstance(coreml, dict) or coreml.get("format") != "mlmodelc" or coreml.get("precision") != "float32":
        raise ValueError("Invalid top-level Core ML manifest")
    paths: set[str] = set()
    for name in ("raw", "rgb"):
        directory = f"{name}.mlmodelc"
        paths.update(_coreml_files(root, coreml.get(name), directory, context=f"coreml.{name}"))
    blind = manifest["blind_rgb"]
    if "coreml" not in blind:
        raise ValueError("Mac model package is missing blind_rgb.coreml resources")
    paths.update(
        _coreml_files(
            root,
            blind["coreml"],
            "blind_rgb.mlmodelc",
            context="blind_rgb.coreml",
            require_precision=True,
        )
    )
    return paths


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

    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False, onerror=on_error):
        current_path = Path(current)
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"Refusing symbolic link in model directory: {relative}")
            if not stat.S_ISDIR(mode):
                raise ValueError(f"Refusing special file in model directory: {relative}")
            _validate_relative_path(relative, context="model directory")
            _record_casefold_path(folded, relative)
            directories.add(relative)
        for name in filenames:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"Refusing symbolic link in model directory: {relative}")
            if not stat.S_ISREG(mode):
                raise ValueError(f"Refusing special file in model directory: {relative}")
            _validate_relative_path(relative, context="model directory")
            _record_casefold_path(folded, relative)
            files[relative] = path
    return files, directories


def _record_casefold_path(folded: dict[str, str], relative: str) -> None:
    key = relative.casefold()
    previous = folded.get(key)
    if previous is not None:
        if previous == relative:
            raise ValueError(f"Duplicate model path: {relative}")
        raise ValueError(f"Case-insensitive model path collision: {previous} and {relative}")
    folded[key] = relative


def _expected_tree_paths(root: Path, manifest: dict, *, include_coreml: bool) -> tuple[set[str], set[str]]:
    files = {"manifest.json", *BASE_FILES}
    directories: set[str] = set()
    if include_coreml:
        coreml_files = _validate_coreml(root, manifest, required=True)
        files.update(coreml_files)
        for relative in coreml_files:
            parent = PurePosixPath(relative).parent
            while str(parent) != ".":
                directories.add(parent.as_posix())
                parent = parent.parent
    else:
        if "coreml" in manifest or "coreml" in manifest.get("blind_rgb", {}):
            raise ValueError("Windows manifest still contains Core ML fields")
        _validate_coreml(root, manifest, required=False)
    return files, directories


def validate_model_tree(root: Path | str, platform: str, *, source_package: bool = False) -> dict:
    """Validate manifest digests and exact platform/source inventory without following links."""
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported platform {platform!r}; expected one of {', '.join(PLATFORMS)}")
    root_path = Path(root)
    files, directories = _walk_model_tree(root_path)
    manifest, _ = _read_manifest(root_path)
    _validate_protocol(manifest)
    _validate_graphs(root_path, manifest)
    _validate_blind_rgb(root_path, manifest)
    include_coreml = source_package or platform == "macos-arm64"
    expected_files, expected_dirs = _expected_tree_paths(root_path, manifest, include_coreml=include_coreml)
    allowed_source_extras = SOURCE_ONLY_TEST_TENSORS if source_package else frozenset()
    missing = sorted(expected_files - set(files))
    if missing:
        raise ValueError(f"Missing required model file: {missing[0]}")
    unexpected_files = sorted(set(files) - expected_files - allowed_source_extras)
    if unexpected_files:
        raise ValueError(f"File is not on the {platform} allow-list: {unexpected_files[0]}")
    unexpected_dirs = sorted(directories - expected_dirs)
    if unexpected_dirs:
        raise ValueError(f"Directory is not on the {platform} allow-list: {unexpected_dirs[0]}")
    missing_dirs = sorted(expected_dirs - directories)
    if missing_dirs:
        raise ValueError(f"Missing required model directory: {missing_dirs[0]}")
    return manifest


def strip_coreml_fields(manifest: dict) -> dict:
    """Apply the same two-field Windows manifest transformation used by build.ps1."""
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
    """Copy only validated platform members to a new tree; never mutate source."""
    source_path = Path(source)
    if source_path.is_symlink():
        raise ValueError(f"Refusing symbolic-link model directory: {source_path}")
    source_path = source_path.resolve()
    destination_path = Path(destination)
    if _path_is_inside(destination_path, source_path):
        raise ValueError(f"Output path must be outside source model directory: {destination_path}")
    validate_model_tree(source_path, platform, source_package=True)
    if destination_path.exists() or destination_path.is_symlink():
        raise ValueError(f"Destination already exists: {destination_path}")
    manifest, _ = _read_manifest(source_path)
    all_source_files, _ = _walk_model_tree(source_path)
    output_manifest = strip_coreml_fields(manifest) if platform == "windows-x64" else manifest
    include_coreml = platform == "macos-arm64"
    expected_files, _ = _expected_tree_paths(source_path, output_manifest, include_coreml=include_coreml)
    try:
        destination_path.mkdir(parents=True)
        for relative in sorted(expected_files):
            destination_file = destination_path / relative
            destination_file.parent.mkdir(parents=True, exist_ok=True)
            if relative == "manifest.json" and platform == "windows-x64":
                output_manifest = strip_coreml_fields(manifest)
                destination_file.write_text(
                    json.dumps(output_manifest, ensure_ascii=False, separators=(",", ":")) + "\n",
                    encoding="utf-8",
                )
            else:
                shutil.copyfile(all_source_files[relative], destination_file)
        validate_model_tree(destination_path, platform)
    except Exception:
        shutil.rmtree(destination_path, ignore_errors=True)
        raise
    return destination_path


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
                    members = sorted((*directories, *files))
                    for relative in members:
                        info = tarfile.TarInfo(relative)
                        info.mtime = 0
                        info.uid = 0
                        info.gid = 0
                        info.uname = ""
                        info.gname = ""
                        info.pax_headers = {}
                        if relative in directories:
                            info.type = tarfile.DIRTYPE
                            info.mode = 0o755
                            info.size = 0
                            tar.addfile(info)
                        else:
                            info.type = tarfile.REGTYPE
                            info.mode = 0o644
                            info.size = files[relative].stat().st_size
                            with files[relative].open("rb") as source_file:
                                tar.addfile(info, source_file)
        os.replace(temporary, archive)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return archive


def _archive_inventory(archive_path: Path) -> tuple[list[dict], int, str]:
    entries: list[dict] = []
    folded: dict[str, str] = {}
    kinds: dict[str, str] = {}
    manifest_sha: str | None = None
    unpacked_bytes = 0
    try:
        with tarfile.open(archive_path, mode="r:gz") as tar:
            for member in tar:
                if member.issym() or member.islnk():
                    raise ValueError(f"Refusing link member in archive: {member.name}")
                if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
                    raise ValueError(f"Refusing non-file archive member: {member.name}")
                if member.pax_headers:
                    raise ValueError(f"Refusing extended metadata in archive member: {member.name}")
                if member.linkname:
                    raise ValueError(f"Refusing link target in archive member: {member.name}")
                raw_name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
                _validate_relative_path(raw_name, context="archive member")
                _record_casefold_path(folded, raw_name)
                if member.isdir():
                    if member.size != 0:
                        raise ValueError(f"Directory archive member has data: {raw_name}")
                    kinds[raw_name] = "directory"
                    entries.append({"path": raw_name, "kind": "directory", "bytes": 0})
                    continue
                if member.size < 0:
                    raise ValueError(f"Invalid archive member size: {raw_name}")
                stream = tar.extractfile(member)
                if stream is None:
                    raise ValueError(f"Cannot read archive member: {raw_name}")
                digest = hashlib.sha256()
                size = 0
                with stream:
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        size += len(chunk)
                if size != member.size:
                    raise ValueError(f"Archive member size mismatch: {raw_name}")
                sha = digest.hexdigest()
                if raw_name == "manifest.json":
                    manifest_sha = sha
                kinds[raw_name] = "file"
                entries.append({"path": raw_name, "kind": "file", "bytes": size, "sha256": sha})
                unpacked_bytes += size
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise ValueError(f"Invalid tar.gz archive {archive_path}: {exc}") from exc
    for relative, kind in kinds.items():
        parent = PurePosixPath(relative).parent
        while str(parent) != ".":
            parent_name = parent.as_posix()
            parent_kind = kinds.get(parent_name)
            if parent_kind == "file":
                raise ValueError(f"Archive file is used as a directory: {parent_name}")
            parent = parent.parent
    if manifest_sha is None:
        raise ValueError("Archive is missing root manifest.json")
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
    """Mirror these native-client checks: match archive SHA-256/bytes/name and exact members; accept only
    normalized relative POSIX paths without absolute roots, drive prefixes, backslashes, empty, dot or
    parent components; reject links, special files, extended metadata, duplicates and case-fold collisions.
    """
    archive = Path(archive_path)
    if (
        not isinstance(description, dict)
        or isinstance(description.get("schemaVersion"), bool)
        or description.get("schemaVersion") != 1
    ):
        raise ValueError("Unsupported AI model archive description")
    platform = description.get("platform")
    if platform not in PLATFORMS:
        raise ValueError("Description has an unsupported platform")
    expected_sha = description.get("archiveSha256")
    expected_bytes = description.get("archiveBytes")
    if not isinstance(expected_sha, str) or _SHA256_RE.fullmatch(expected_sha) is None:
        raise ValueError("Description has an invalid archive SHA-256")
    if isinstance(expected_bytes, bool) or not isinstance(expected_bytes, int) or expected_bytes < 0:
        raise ValueError("Description has an invalid archive size")
    actual_sha, actual_bytes = _sha256_file(archive)
    if actual_sha != expected_sha:
        raise ValueError(f"Archive SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
    if actual_bytes != expected_bytes:
        raise ValueError(f"Archive size mismatch: expected {expected_bytes}, got {actual_bytes}")
    expected_name = description.get("archiveName")
    if expected_name != archive.name:
        raise ValueError(f"Archive name mismatch: expected {expected_name!r}, got {archive.name!r}")
    named_platform, named_prefix = _archive_platform_and_digest_name(archive)
    if named_platform != platform or named_prefix != actual_sha[:12]:
        raise ValueError("Archive filename does not match its platform and SHA-256")
    expected_manifest_sha = description.get("manifestSha256")
    if not isinstance(expected_manifest_sha, str) or _SHA256_RE.fullmatch(expected_manifest_sha) is None:
        raise ValueError("Description has an invalid manifest SHA-256")
    expected_unpacked_bytes = description.get("unpackedBytes")
    if (
        isinstance(expected_unpacked_bytes, bool)
        or not isinstance(expected_unpacked_bytes, int)
        or expected_unpacked_bytes < 0
    ):
        raise ValueError("Description has an invalid unpacked size")
    expected_entries = description.get("entries")
    if not isinstance(expected_entries, list):
        raise ValueError("Description has no member list")
    for entry in expected_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ValueError("Description has an invalid member entry")
        if entry.get("kind") not in ("file", "directory"):
            raise ValueError(f"Description has an invalid member kind: {entry.get('kind')!r}")
        entry_bytes = entry.get("bytes")
        if isinstance(entry_bytes, bool) or not isinstance(entry_bytes, int) or entry_bytes < 0:
            raise ValueError(f"Description has an invalid member size: {entry['path']}")
        if entry["kind"] == "file":
            entry_sha = entry.get("sha256")
            if not isinstance(entry_sha, str) or _SHA256_RE.fullmatch(entry_sha) is None:
                raise ValueError(f"Description has an invalid member SHA-256: {entry['path']}")
    actual_entries, unpacked_bytes, manifest_sha = _archive_inventory(archive)
    if manifest_sha != expected_manifest_sha:
        raise ValueError(f"Manifest SHA-256 mismatch: expected {expected_manifest_sha}, got {manifest_sha}")
    if actual_entries != expected_entries:
        raise ValueError("Archive members do not match the description")
    if expected_unpacked_bytes != unpacked_bytes:
        raise ValueError(
            f"Unpacked size mismatch: expected {expected_unpacked_bytes}, got {unpacked_bytes}"
        )


def _write_description(path: Path, description: dict) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(description, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _build_one(source: Path, platform: str, output_dir: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix=f"rawlab-ai-{platform}-") as temporary_dir:
        temporary_root = Path(temporary_dir)
        tree = prepare_model_tree(source, platform, temporary_root / "tree")
        staged_archive = create_model_archive(tree, temporary_root / "staged.tar.gz")
        digest, _ = _sha256_file(staged_archive)
        final_archive = output_dir / f"rawlab-ai-{platform}-{digest[:12]}.tar.gz"
        if final_archive.exists():
            existing_digest, existing_size = _sha256_file(final_archive)
            staged_digest, staged_size = _sha256_file(staged_archive)
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
    descriptions = [_build_one(source, platform, output_dir) for platform in platforms]
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
    build_parser = subparsers.add_parser("build", help="build platform archives from a validated model directory")
    build_parser.add_argument("--source", required=True, help="validated complete DualDn model directory")
    build_parser.add_argument("--output-dir", required=True, help="directory for archives and JSON descriptions")
    build_parser.add_argument(
        "--platform", choices=(*PLATFORMS, "all"), default="all", help="platform to build (default: all)"
    )
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
