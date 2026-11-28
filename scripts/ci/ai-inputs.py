#!/usr/bin/env python3
"""Locate or restore the pinned noncommercial model package and fetch the desktop runtime."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import tarfile
import tempfile
import urllib.request

MANIFEST = "38cbd6884bb181db859ffc668cf754a55331be732592e0d4cdf9a2d41a19486a"
ORT = {"arm64": "b4d513ab2b26f088c66891dbbc1408166708773d7cc4163de7bdca0e9bbb7856",
       "x86_64": "d10359e16347b57d9959f7e80a225a5b4a66ed7d7e007274a15cae86836485a6"}
ORT_LIBRARY = {"arm64": "d306d2bc768540766c7ed8a1e0ff05d2870c77a934ebeee4a7bafa1b732ef299",
               "x86_64": "8c9c78de65ea3786f987c0d980e9c1b13a3a5fbc6b3e2965ba05b450e6e4c054"}

REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = REPO_ROOT / "Shared" / "ai-models" / "catalog.json"
REPLAY_DESCRIPTION_PATH = Path(__file__).resolve().with_name("ai-replay-tensors.json")
MODEL_ARCHIVE_PLATFORM = "macos-arm64"


def _load_helper(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load helper module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_PREPARE = _load_helper("rawlab_assets_prepare", REPO_ROOT / "scripts" / "assets" / "prepare.py")
_PACKAGE = _load_helper("rawlab_package_ai_models", REPO_ROOT / "scripts" / "assets" / "package_ai_models.py")


def digest(path):
    return _PREPARE.sha256_file(path)[0]


def _load_archive_descriptions(catalog_path: Path, replay_path: Path) -> tuple[dict, dict]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 1:
        raise ValueError(f"Unsupported AI model catalog schema: {catalog_path}")
    platforms = catalog.get("platforms")
    if not isinstance(platforms, dict) or not isinstance(platforms.get(MODEL_ARCHIVE_PLATFORM), dict):
        raise ValueError(f"Missing {MODEL_ARCHIVE_PLATFORM} description in {catalog_path}")
    model_desc = platforms[MODEL_ARCHIVE_PLATFORM]
    replay_desc = json.loads(replay_path.read_text(encoding="utf-8"))
    if not isinstance(replay_desc, dict):
        raise ValueError(f"Unsupported AI replay tensor description: {replay_path}")
    if model_desc.get("manifestSha256") != MANIFEST:
        raise ValueError(f"Model catalog manifest SHA-256 mismatch: expected {MANIFEST}")
    if replay_desc.get("manifestSha256") != MANIFEST:
        raise ValueError(f"Replay description manifest SHA-256 mismatch: expected {MANIFEST}")
    return model_desc, replay_desc


def _require_archive_fields(description: dict) -> tuple[str, str, str, int, list[dict]]:
    url = description.get("url")
    archive_name = description.get("archiveName")
    archive_sha = description.get("archiveSha256")
    archive_bytes = description.get("archiveBytes")
    entries = description.get("entries")
    if not isinstance(url, str) or not url.strip():
        raise ValueError("Archive description is missing a download URL")
    if (not isinstance(archive_name, str) or not archive_name
            or "/" in archive_name or "\\" in archive_name or Path(archive_name).name != archive_name):
        raise ValueError(f"Invalid archive filename in description: {archive_name!r}")
    if not isinstance(archive_sha, str) or _PACKAGE._SHA256_RE.fullmatch(archive_sha) is None:
        raise ValueError("Archive description has an invalid SHA-256")
    if type(archive_bytes) is not int or archive_bytes < 0:
        raise ValueError("Archive description has an invalid byte size")
    if not isinstance(entries, list):
        raise ValueError("Archive description has no member list")
    return url, archive_name, archive_sha, archive_bytes, entries


def _verify_extracted_tree(tree_dir: Path, model_desc: dict, replay_desc: dict) -> None:
    expected_files: dict[str, dict] = {}
    for description in (model_desc, replay_desc):
        for entry in description["entries"]:
            if entry.get("kind") == "file":
                rel = entry["path"]
                if rel in expected_files:
                    raise ValueError(f"Duplicate file path across archive descriptions: {rel}")
                expected_files[rel] = entry

    extracted_files, _ = _PACKAGE._walk_model_tree(tree_dir)
    missing = sorted(set(expected_files) - set(extracted_files))
    if missing:
        raise ValueError(f"Extracted package is missing file: {missing[0]}")
    unexpected = sorted(set(extracted_files) - set(expected_files))
    if unexpected:
        raise ValueError(f"Extracted package contains unexpected file: {unexpected[0]}")
    for rel, entry in expected_files.items():
        if not _PREPARE.file_matches(tree_dir / rel, entry["sha256"], entry["bytes"]):
            raise ValueError(f"Extracted file failed verification: {rel}")
    _PACKAGE.validate_model_tree(tree_dir, MODEL_ARCHIVE_PLATFORM, source_package=True)
    if digest(tree_dir / "manifest.json") != MANIFEST:
        raise ValueError(f"Extracted manifest SHA-256 mismatch; expected {MANIFEST}")


def restore_model_package(
    model_dir: Path,
    *,
    catalog_path: Path | None = None,
    replay_path: Path | None = None,
) -> None:
    model_desc, replay_desc = _load_archive_descriptions(
        CATALOG_PATH if catalog_path is None else catalog_path,
        REPLAY_DESCRIPTION_PATH if replay_path is None else replay_path,
    )
    specs = (
        (model_desc, _PACKAGE.verify_model_archive),
        (replay_desc, _PACKAGE.verify_replay_archive),
    )
    seen_paths: set[str] = set()
    for desc, _ in specs:
        _, _, _, _, entries = _require_archive_fields(desc)
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                raise ValueError("Archive description has an invalid member entry")
            if entry["path"] in seen_paths:
                raise ValueError(f"Overlapping archive entry across descriptions: {entry['path']}")
            seen_paths.add(entry["path"])

    model_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".stage-", dir=model_dir.parent) as stage_root_str:
        stage_root = Path(stage_root_str)
        downloads_dir = stage_root / "downloads"
        tree_dir = stage_root / "tree"
        downloads_dir.mkdir()
        tree_dir.mkdir()
        for desc, verifier in specs:
            url, archive_name, archive_sha, archive_bytes, _ = _require_archive_fields(desc)
            archive_path = downloads_dir / archive_name
            _PREPARE.download_with_retry(url, archive_path, archive_sha, archive_bytes)
            verifier(archive_path, desc)
            _PREPARE._safe_extract_tar_gz(archive_path, tree_dir)
        _verify_extracted_tree(tree_dir, model_desc, replay_desc)
        tree_dir.rename(model_dir)


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("macos", "windows"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args(argv)
    cache = Path(os.environ.get("RAWLAB_AI_SHARED_CACHE", Path.home() / ".cache/rawlab-ci"))
    explicit_model_dir = os.environ.get("RAWLAB_DUALDN_MODEL_DIR")
    if explicit_model_dir is not None:
        model = Path(explicit_model_dir)
    else:
        model = cache / "ai-models" / MANIFEST / "complete"
        if not model.exists() and not model.is_symlink():
            restore_model_package(model)
    if not (model / "manifest.json").is_file() or digest(model / "manifest.json") != MANIFEST:
        raise ValueError(f"Provision the licensed DualDn/Restormer package at {model}; expected manifest SHA-256 {MANIFEST}")
    manifest = json.loads((model / "manifest.json").read_text())
    if "blind_rgb" not in manifest:
        raise ValueError("The CI model must include the generic RGB denoiser")
    values = {"RAWLAB_DUALDN": "1", "RAWLAB_DUALDN_MODEL_DIR": str(model.resolve()), "RAWLAB_DUALDN_MANIFEST_SHA256": MANIFEST}
    if args.platform == "macos":
        for name in ("raw.mlmodelc", "rgb.mlmodelc", "blind_rgb.mlmodelc"):
            if not (model / name).is_dir():
                raise ValueError(f"Missing Core ML release model: {name}")
        name = f"onnxruntime-osx-{args.arch}-1.23.2"
        root = cache / "onnxruntime" / "1.23.2"
        root.mkdir(parents=True, exist_ok=True)
        archive = root / f"{name}.tgz"
        if not archive.is_file():
            temporary = archive.with_suffix(".download")
            try:
                urllib.request.urlretrieve(f"https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/{name}.tgz", temporary)
                if digest(temporary) != ORT[args.arch]:
                    raise ValueError("ONNX Runtime archive SHA-256 mismatch")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
        if digest(archive) != ORT[args.arch]:
            raise ValueError("Cached ONNX Runtime archive SHA-256 mismatch")
        runtime = root / name
        if not runtime.is_dir():
            with tempfile.TemporaryDirectory(dir=root) as stage:
                with tarfile.open(archive) as bundle:
                    bundle.extractall(stage, filter="data")
                Path(stage, name).rename(runtime)
        if digest(runtime / "lib/libonnxruntime.1.23.2.dylib") != ORT_LIBRARY[args.arch]:
            raise ValueError("Cached ONNX Runtime library SHA-256 mismatch")
        values["RAWLAB_ONNXRUNTIME_ROOT"] = str(runtime.resolve())
    output = os.environ.get("GITHUB_ENV")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            for key, value in values.items():
                if "\n" in value or "\r" in value:
                    raise ValueError("Invalid environment path")
                stream.write(f"{key}={value}\n")
    else:
        print(json.dumps(values, indent=2))


if __name__ == "__main__":
    main()
