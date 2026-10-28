#!/usr/bin/env python3
"""Prepare pinned read-only codec sources in the primary checkout shared cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import fcntl
import tempfile

MANIFEST = Path(__file__).with_name("hdr-codec-dependencies.json")

def digest(path):
    with path.open("rb") as source:
        value = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
        return value.hexdigest()


def prepare_source(cache, pin, archive_name, folder):
    archive = cache / "hdr-codecs" / archive_name
    shared_mac_archive = cache / "macos-sources" / archive_name
    if not archive.exists() and shared_mac_archive.exists():
        archive = shared_mac_archive
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = archive.with_suffix(f".part-{os.getpid()}")
        try:
            with urllib.request.urlopen(pin["url"], timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(temporary) != pin["sha256"]:
                raise RuntimeError(f"Dependency checksum mismatch: {archive_name}")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(archive) != pin["sha256"]:
        raise RuntimeError(f"Dependency checksum mismatch: {archive_name}")
    destination = cache / "hdr-codecs" / folder
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix=".hdr-source-", dir=cache / "hdr-codecs") as temporary:
            with tarfile.open(archive) as source:
                for member in source.getmembers():
                    parts = Path(member.name).parts
                    if not parts or Path(member.name).is_absolute() or ".." in parts or parts[0]!=folder or member.issym() or member.islnk():
                        raise RuntimeError("Dependency archive contains unsafe paths or links")
                source.extractall(temporary, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
            candidate=Path(temporary)/folder
            if not (candidate/"CMakeLists.txt").is_file() or any(not (candidate/name).is_file() for name in pin["license_files"]):
                raise RuntimeError(f"Incomplete extracted dependency: {folder}")
            candidate.rename(destination)
    if not destination.is_dir():
        raise RuntimeError(f"Missing extracted dependency: {folder}")
    return destination


def shared_cache():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    primary = Path(result.stdout.strip()).parent if result.returncode == 0 else root
    return primary / ".cache" / "shared"


def prepare(cache):
    pins = json.loads(MANIFEST.read_text())
    directory = cache / "hdr-codecs"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        uhdr = prepare_source(cache, pins["libultrahdr"], "libultrahdr-v2.0.2.tar.gz", "libultrahdr-2.0.2")
        jpeg = prepare_source(cache, pins["libjpeg_turbo"], "libjpeg-turbo-3.1.3.tar.gz", "libjpeg-turbo-3.1.3")
    return uhdr, jpeg


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path)
    args = parser.parse_args()
    print(";".join(str(path) for path in prepare(args.cache_root or shared_cache())))
