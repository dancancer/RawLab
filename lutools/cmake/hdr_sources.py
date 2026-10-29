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
import tempfile
from contextlib import contextmanager

MANIFEST = Path(__file__).with_name("hdr-codec-dependencies.json")

@contextmanager
def source_lock(path):
    # 同一缓存可被多个平台构建共享；Windows 没有 fcntl。
    with path.open("a+b") as lock:
        if os.name == "nt":
            import msvcrt
            lock.seek(0, 2)
            if not lock.tell():
                lock.write(b"\0")
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)

def digest(path):
    with path.open("rb") as source:
        value = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
        return value.hexdigest()



def verify_extracted(destination, archive, folder):
    expected = set()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if not member.isfile():
                continue
            relative = Path(member.name).relative_to(folder)
            expected.add(relative)
            file = destination / relative
            if file.is_symlink() or not file.is_file() or file.stat().st_size != member.size:
                raise RuntimeError(f"Extracted dependency differs from pinned archive: {file}")
            value = hashlib.sha256()
            with source.extractfile(member) as content:
                for block in iter(lambda: content.read(1024 * 1024), b""):
                    value.update(block)
            if digest(file) != value.hexdigest():
                raise RuntimeError(f"Extracted dependency differs from pinned archive: {file}")
    for file in destination.rglob("*"):
        if file.is_symlink() or (not file.is_dir() and file.relative_to(destination) not in expected):
            raise RuntimeError(f"Extracted dependency contains unpinned content: {file}")


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
                    if not parts or Path(member.name).is_absolute() or ".." in parts or parts[0]!=folder or not (member.isfile() or member.isdir()):
                        raise RuntimeError("Dependency archive contains unsafe paths or links")
                source.extractall(temporary, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
            candidate=Path(temporary)/folder
            if not (candidate/"CMakeLists.txt").is_file() or any(not (candidate/name).is_file() for name in pin["license_files"]):
                raise RuntimeError(f"Incomplete extracted dependency: {folder}")
            candidate.rename(destination)
    if not destination.is_dir():
        raise RuntimeError(f"Missing extracted dependency: {folder}")
    verify_extracted(destination, archive, folder)
    return destination


def shared_cache():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    primary = Path(result.stdout.strip()).parent if result.returncode == 0 else root
    return primary / ".cache" / "shared"


def prepare(cache, portable=False):
    pins = json.loads(MANIFEST.read_text())
    directory = cache / "hdr-codecs"
    directory.mkdir(parents=True, exist_ok=True)
    with source_lock(directory / ".prepare.lock"):
        uhdr = prepare_source(cache, pins["libultrahdr"], "libultrahdr-v2.0.2.tar.gz", "libultrahdr-2.0.2")
        jpeg = prepare_source(cache, pins["libjpeg_turbo"], "libjpeg-turbo-3.1.3.tar.gz", "libjpeg-turbo-3.1.3")
        sources = [uhdr, jpeg]
        if portable:
            for name in ("libheif", "libde265", "lcms2"):
                pin = pins[name]
                sources.append(prepare_source(cache, pin, pin["archive"], pin["folder"]))
    return sources


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path)
    parser.add_argument("--portable", action="store_true")
    args = parser.parse_args()
    print(";".join(str(path) for path in prepare(args.cache_root or shared_cache(), args.portable)))
