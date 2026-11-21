#!/usr/bin/env python3
"""Fetch, verify, cache, and materialize externalized RawLab binary/LUT assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "Shared" / "assets-manifest.json"
DOWNLOAD_ATTEMPTS = 4
DOWNLOAD_TIMEOUT_SECONDS = 120


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def file_matches(path: Path, expected_sha256: str, expected_bytes: int | None = None) -> bool:
    if not path.is_file():
        return False
    if expected_bytes is not None and path.stat().st_size != expected_bytes:
        return False
    actual_sha256, _ = sha256_file(path)
    return actual_sha256 == expected_sha256


def resolve_cache_root(repo_root: Path, env: dict[str, str] | None = None) -> Path:
    env_map = os.environ if env is None else env
    override = env_map.get("RAWLAB_ASSET_CACHE", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    try:
        common_git = subprocess.check_output(
            ["git", "-C", str(repo_root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if common_git:
            return Path(common_git).parent / ".cache" / "shared" / "assets"
    except (OSError, subprocess.CalledProcessError):
        pass
    return repo_root / ".cache" / "shared" / "assets"


def load_manifest(manifest_path: Path) -> dict:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1 or not isinstance(data.get("groups"), dict):
        raise ValueError(f"Unsupported assets manifest schema: {manifest_path}")
    return data


def validate_release_policy(manifest: dict) -> dict[str, bool]:
    """Ensure externalized asset packs stay prerelease-only and never steal Latest."""
    policy = manifest.get("releasePolicy")
    if not isinstance(policy, dict):
        raise ValueError("Missing or invalid top-level 'releasePolicy' object in assets manifest")
    prerelease = policy.get("prerelease")
    make_latest = policy.get("makeLatest")
    if not isinstance(prerelease, bool) or not isinstance(make_latest, bool):
        raise ValueError("assets manifest 'releasePolicy' must define boolean 'prerelease' and 'makeLatest'")
    if prerelease is not True:
        raise ValueError("assets manifest releasePolicy.prerelease must be true")
    if make_latest is not False:
        raise ValueError("assets manifest releasePolicy.makeLatest must be false so asset packs cannot steal Latest")
    return {"prerelease": prerelease, "makeLatest": make_latest}


def build_gh_release_args(
    manifest: dict,
    action: str = "create",
    *,
    title: str | None = None,
    notes: str | None = None,
    files: list[str] | tuple[str, ...] | None = None,
) -> list[str]:
    """Build guarded `gh release create/edit` argv enforcing `--prerelease --latest=false`."""
    if action not in ("create", "edit"):
        raise ValueError(f"Unsupported gh release action: {action!r}")
    validate_release_policy(manifest)
    tag = manifest.get("releaseTag")
    if not isinstance(tag, str) or not tag.strip():
        raise ValueError("assets manifest must define a non-empty 'releaseTag'")
    cmd = ["gh", "release", action, tag.strip(), "--prerelease", "--latest=false"]
    if title is not None:
        cmd.extend(["--title", title])
    if notes is not None:
        cmd.extend(["--notes", notes])
    if files:
        if action != "create":
            raise ValueError("Asset file arguments are only supported for 'gh release create'")
        cmd.extend(files)
    return cmd


def selected_groups(manifest: dict, group: str) -> list[tuple[str, dict]]:
    groups = manifest["groups"]
    if group == "all":
        return list(groups.items())
    if group not in groups:
        raise ValueError(f"Unknown asset group '{group}'; expected one of: {', '.join(groups)}, all")
    return [(group, groups[group])]


def download_with_retry(url: str, dest: Path, expected_sha256: str, expected_bytes: int | None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(f"{dest.name}.{os.getpid()}.part")
    last_error: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        part.unlink(missing_ok=True)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "RawLab-Asset-Prepare/1.0"})
            with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
                with part.open("wb") as out:
                    shutil.copyfileobj(response, out, length=1024 * 1024)
            actual_sha256, actual_bytes = sha256_file(part)
            if expected_bytes is not None and actual_bytes != expected_bytes:
                raise ValueError(f"Size mismatch for {url}: expected {expected_bytes}, got {actual_bytes}")
            if actual_sha256 != expected_sha256:
                raise ValueError(f"SHA-256 mismatch for {url}: expected {expected_sha256}, got {actual_sha256}")
            os.replace(part, dest)
            return
        except (OSError, urllib.error.URLError, ValueError) as exc:
            last_error = exc
            part.unlink(missing_ok=True)
            if attempt < DOWNLOAD_ATTEMPTS:
                time.sleep(min(2 ** (attempt - 1), 8))
    raise RuntimeError(f"Failed to download verified asset archive {url}: {last_error}")


def _safe_extract_tar_gz(archive: Path, target_dir: Path) -> None:
    target_resolved = target_dir.resolve()
    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            if member.issym() or member.islnk():
                raise ValueError(f"Refusing link member in asset archive: {member.name}")
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise ValueError(f"Refusing unsafe path in asset archive: {member.name}")
            resolved = (target_resolved / member_path).resolve()
            if resolved != target_resolved and target_resolved not in resolved.parents:
                raise ValueError(f"Archive path escapes extraction root: {member.name}")
        if sys.version_info >= (3, 12):
            tf.extractall(target_resolved, filter="data")
        else:
            tf.extractall(target_resolved)


def _materialize_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        dest.unlink()
    try:
        os.link(src, dest)
    except OSError:
        tmp = dest.with_name(f".{dest.name}.{os.getpid()}.tmp")
        tmp.unlink(missing_ok=True)
        try:
            shutil.copy2(src, tmp)
            os.replace(tmp, dest)
        finally:
            tmp.unlink(missing_ok=True)


def check_group(repo_root: Path, name: str, spec: dict) -> list[str]:
    problems: list[str] = []
    for entry in spec["files"]:
        rel = entry["path"]
        dest = repo_root / rel
        if not dest.is_file():
            problems.append(f"[{name}] missing: {rel}")
            continue
        actual_sha256, actual_bytes = sha256_file(dest)
        if actual_bytes != entry["bytes"] or actual_sha256 != entry["sha256"]:
            problems.append(
                f"[{name}] mismatch: {rel} (expected sha256={entry['sha256']} bytes={entry['bytes']}, "
                f"got sha256={actual_sha256} bytes={actual_bytes})"
            )
    return problems


def prepare_group(
    repo_root: Path,
    cache_root: Path,
    name: str,
    spec: dict,
    *,
    offline: bool = False,
    quiet: bool = False,
) -> tuple[int, int]:
    files = spec["files"]
    if all(file_matches(repo_root / entry["path"], entry["sha256"], entry["bytes"]) for entry in files):
        if not quiet:
            print(f"[assets:{name}] up-to-date ({len(files)} files verified)")
        return len(files), 0

    group_cache = cache_root / spec["sha256"]
    extracted_dir = group_cache / "extracted"
    archive_path = group_cache / spec["archive"]

    cache_ready = all(
        file_matches(extracted_dir / entry["path"], entry["sha256"], entry["bytes"]) for entry in files
    )
    if not cache_ready:
        if archive_path.is_file() and not file_matches(archive_path, spec["sha256"], spec.get("bytes")):
            if not quiet:
                print(f"[assets:{name}] cached archive failed SHA-256 check; removing {archive_path}", file=sys.stderr)
            archive_path.unlink(missing_ok=True)

        if not archive_path.is_file():
            if offline:
                raise RuntimeError(
                    f"Missing cached archive {archive_path} in offline mode; run without --offline to fetch {spec['url']}"
                )
            if not quiet:
                print(f"[assets:{name}] downloading {spec['url']} -> {archive_path}")
            download_with_retry(spec["url"], archive_path, spec["sha256"], spec.get("bytes"))
        elif not quiet:
            print(f"[assets:{name}] verified cached archive {archive_path}")

        stage_dir = group_cache / f"stage.{os.getpid()}"
        if stage_dir.exists():
            shutil.rmtree(stage_dir)
        stage_dir.mkdir(parents=True, exist_ok=True)
        try:
            _safe_extract_tar_gz(archive_path, stage_dir)
            for entry in files:
                staged_file = stage_dir / entry["path"]
                if not file_matches(staged_file, entry["sha256"], entry["bytes"]):
                    raise RuntimeError(f"Extracted file failed verification: {entry['path']}")
            for entry in files:
                dest_cache = extracted_dir / entry["path"]
                if not file_matches(dest_cache, entry["sha256"], entry["bytes"]):
                    dest_cache.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(stage_dir / entry["path"], dest_cache)
        finally:
            shutil.rmtree(stage_dir, ignore_errors=True)

    materialized = 0
    for entry in files:
        dest = repo_root / entry["path"]
        if file_matches(dest, entry["sha256"], entry["bytes"]):
            continue
        cached = extracted_dir / entry["path"]
        _materialize_file(cached, dest)
        materialized += 1

    if not quiet:
        print(f"[assets:{name}] materialized {materialized} file(s) ({len(files)} total verified)")
    return len(files), materialized


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("luts", "raw", "all"), default="all", help="Asset group to prepare or check")
    parser.add_argument("--check", action="store_true", help="Verify materialized files against manifest without downloading")
    parser.add_argument(
        "--check-release-policy",
        action="store_true",
        help="Verify manifest releasePolicy prevents asset releases from marking Latest",
    )
    parser.add_argument(
        "--print-gh-release-args",
        choices=("create", "edit"),
        help="Print guarded gh release CLI command for the manifest releaseTag",
    )
    parser.add_argument("--offline", action="store_true", help="Materialize from local shared cache only; fail if missing")
    parser.add_argument("--quiet", action="store_true", help="Suppress informational output")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST, help="Path to assets-manifest.json")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT, help="Repository/worktree root")
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    manifest_path = args.manifest if args.manifest.is_absolute() else (repo_root / args.manifest)
    manifest = load_manifest(manifest_path)

    if args.check_release_policy or args.print_gh_release_args:
        try:
            policy = validate_release_policy(manifest)
            cmd = build_gh_release_args(manifest, args.print_gh_release_args or "create")
        except ValueError as exc:
            print(f"[assets:release-policy] {exc}", file=sys.stderr)
            return 1
        if args.print_gh_release_args:
            print(shlex.join(cmd))
        elif not args.quiet:
            print(
                f"[assets:release-policy] OK (tag={manifest['releaseTag']}, "
                f"prerelease={str(policy['prerelease']).lower()}, "
                f"makeLatest={str(policy['makeLatest']).lower()})"
            )
        if not args.check:
            return 0

    groups = selected_groups(manifest, args.group)

    if args.check:
        problems: list[str] = []
        for name, spec in groups:
            problems.extend(check_group(repo_root, name, spec))
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            print(
                "Run `python3 scripts/assets/prepare.py --group "
                + args.group
                + "` to materialize verified assets.",
                file=sys.stderr,
            )
            return 1
        if not args.quiet:
            total = sum(len(spec["files"]) for _, spec in groups)
            print(f"[assets:{args.group}] OK ({total} files verified)")
        return 0

    cache_root = resolve_cache_root(repo_root)
    for name, spec in groups:
        prepare_group(repo_root, cache_root, name, spec, offline=args.offline, quiet=args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
