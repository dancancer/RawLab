#!/usr/bin/env python3
"""Sync and verify RawLab app version/build numbers from Shared/version.json."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
VERSION_SOURCE = "Shared/version.json"
SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

IOS_PLIST = "RawLab/RawLab/Resources/Info.plist"
MAC_PLIST = "RawLabMac/Info.plist"
ANDROID_GRADLE = "RawLabAndroid/app/build.gradle.kts"
WINDOWS_CSPROJ = "RawLabWindows/RawLabWindows.csproj"


def load_version_source(root: Path) -> tuple[str, int]:
    path = root / VERSION_SOURCE
    if not path.is_file():
        raise ValueError(f"Missing single version source: {VERSION_SOURCE}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON in {VERSION_SOURCE}: {exc}") from exc
    if not isinstance(data, dict) or set(data.keys()) != {"version", "build"}:
        raise ValueError(f"{VERSION_SOURCE} must contain exactly keys 'version' and 'build'")
    version = data["version"]
    build = data["build"]
    if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
        raise ValueError(f"Invalid version in {VERSION_SOURCE}: {version!r} (expected MAJOR.MINOR.PATCH)")
    if any(int(part) > 65535 for part in version.split(".")):
        raise ValueError(f"Version components in {VERSION_SOURCE} must be <= 65535 for Windows FileVersion: {version!r}")
    if isinstance(build, bool) or not isinstance(build, int) or build < 1 or build > 65535:
        raise ValueError(f"Invalid build in {VERSION_SOURCE}: {build!r} (expected integer 1..65535)")
    return version, build


def _check_plist(root: Path, rel_path: str, version: str, build: int) -> list[str]:
    path = root / rel_path
    if not path.is_file():
        return [f"Missing file: {rel_path}"]
    raw = path.read_bytes()
    try:
        parsed = plistlib.loads(raw)
        xml_root = ET.fromstring(raw.decode("utf-8"))
    except Exception as exc:
        return [f"Invalid plist XML in {rel_path}: {exc}"]
    if not isinstance(parsed, dict):
        return [f"Expected top-level dict in {rel_path}"]
    top_dict = xml_root.find("dict")
    if top_dict is None:
        return [f"Missing top-level <dict> in {rel_path}"]
    keys = [elem.text for elem in top_dict if elem.tag == "key"]
    errors: list[str] = []
    for key, expected in (("CFBundleShortVersionString", version), ("CFBundleVersion", str(build))):
        count = keys.count(key)
        if count != 1:
            errors.append(f"{rel_path}: expected 1 '{key}' key, found {count}")
            continue
        actual = parsed.get(key)
        if actual != expected:
            errors.append(f"{rel_path}: {key}={actual!r}, expected {expected!r}")
    return errors


def _update_plist(root: Path, rel_path: str, version: str, build: int) -> bool:
    path = root / rel_path
    if not path.is_file():
        raise ValueError(f"Missing file: {rel_path}")
    text = path.read_text(encoding="utf-8")
    updated = text
    for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", str(build))):
        pattern = re.compile(rf"(<key>{re.escape(key)}</key>\s*<string>)([^<]*)(</string>)")
        updated, count = pattern.subn(rf"\g<1>{value}\g<3>", updated)
        if count != 1:
            raise ValueError(f"{rel_path}: expected 1 '{key}' <string> entry, found {count}")
    if updated == text:
        return False
    path.write_text(updated, encoding="utf-8")
    errors = _check_plist(root, rel_path, version, build)
    if errors:
        raise ValueError("; ".join(errors))
    return True


_GRADLE_VERSION_CODE_RE = re.compile(r"(?m)^([ \t]*versionCode[ \t]*=[ \t]*)(\S+)([ \t]*(?://.*)?)$")
_GRADLE_VERSION_NAME_RE = re.compile(r'(?m)^([ \t]*versionName[ \t]*=[ \t]*)"([^"\r\n]*)"([ \t]*(?://.*)?)$')


def _check_android_gradle(root: Path, rel_path: str, version: str, build: int) -> list[str]:
    path = root / rel_path
    if not path.is_file():
        return [f"Missing file: {rel_path}"]
    text = path.read_text(encoding="utf-8")
    errors: list[str] = []
    code_matches = _GRADLE_VERSION_CODE_RE.findall(text)
    if len(code_matches) != 1:
        errors.append(f"{rel_path}: expected 1 versionCode assignment, found {len(code_matches)}")
    elif code_matches[0][1] != str(build):
        errors.append(f"{rel_path}: versionCode={code_matches[0][1]!r}, expected {str(build)!r}")

    name_matches = _GRADLE_VERSION_NAME_RE.findall(text)
    if len(name_matches) != 1:
        errors.append(f"{rel_path}: expected 1 versionName assignment, found {len(name_matches)}")
    elif name_matches[0][1] != version:
        errors.append(f"{rel_path}: versionName={name_matches[0][1]!r}, expected {version!r}")
    return errors


def _update_android_gradle(root: Path, rel_path: str, version: str, build: int) -> bool:
    path = root / rel_path
    if not path.is_file():
        raise ValueError(f"Missing file: {rel_path}")
    text = path.read_text(encoding="utf-8")
    updated, code_count = _GRADLE_VERSION_CODE_RE.subn(rf"\g<1>{build}\g<3>", text)
    if code_count != 1:
        raise ValueError(f"{rel_path}: expected 1 versionCode assignment, found {code_count}")
    updated, name_count = _GRADLE_VERSION_NAME_RE.subn(rf'\g<1>"{version}"\g<3>', updated)
    if name_count != 1:
        raise ValueError(f"{rel_path}: expected 1 versionName assignment, found {name_count}")
    if updated == text:
        return False
    path.write_text(updated, encoding="utf-8")
    errors = _check_android_gradle(root, rel_path, version, build)
    if errors:
        raise ValueError("; ".join(errors))
    return True


def _check_windows_csproj(root: Path, rel_path: str, version: str, build: int) -> list[str]:
    path = root / rel_path
    if not path.is_file():
        return [f"Missing file: {rel_path}"]
    try:
        xml_root = ET.fromstring(path.read_text(encoding="utf-8"))
    except ET.ParseError as exc:
        return [f"Invalid XML in {rel_path}: {exc}"]
    expected_map = {
        "Version": version,
        "FileVersion": f"{version}.{build}",
        "InformationalVersion": f"{version}+build.{build}",
    }
    errors: list[str] = []
    for tag, expected in expected_map.items():
        nodes = xml_root.findall(f"./PropertyGroup/{tag}")
        if len(nodes) != 1:
            errors.append(f"{rel_path}: expected 1 <{tag}> element, found {len(nodes)}")
            continue
        actual = (nodes[0].text or "").strip()
        if actual != expected:
            errors.append(f"{rel_path}: <{tag}>={actual!r}, expected {expected!r}")
    return errors


def _update_windows_csproj(root: Path, rel_path: str, version: str, build: int) -> bool:
    path = root / rel_path
    if not path.is_file():
        raise ValueError(f"Missing file: {rel_path}")
    text = path.read_text(encoding="utf-8")
    updated = text
    replacements = {
        "Version": version,
        "FileVersion": f"{version}.{build}",
        "InformationalVersion": f"{version}+build.{build}",
    }
    for tag, value in replacements.items():
        pattern = re.compile(rf"(<{tag}>)([^<]*)(</{tag}>)")
        updated, count = pattern.subn(rf"\g<1>{value}\g<3>", updated)
        if count != 1:
            raise ValueError(f"{rel_path}: expected 1 <{tag}> element, found {count}")
    if updated == text:
        return False
    path.write_text(updated, encoding="utf-8")
    errors = _check_windows_csproj(root, rel_path, version, build)
    if errors:
        raise ValueError("; ".join(errors))
    return True


def check_all(root: Path) -> tuple[str, int, list[str]]:
    version, build = load_version_source(root)
    errors: list[str] = []
    errors.extend(_check_plist(root, IOS_PLIST, version, build))
    errors.extend(_check_plist(root, MAC_PLIST, version, build))
    errors.extend(_check_android_gradle(root, ANDROID_GRADLE, version, build))
    errors.extend(_check_windows_csproj(root, WINDOWS_CSPROJ, version, build))
    return version, build, errors


def sync_all(root: Path) -> tuple[str, int, list[str]]:
    version, build = load_version_source(root)
    changed: list[str] = []
    if _update_plist(root, IOS_PLIST, version, build):
        changed.append(IOS_PLIST)
    if _update_plist(root, MAC_PLIST, version, build):
        changed.append(MAC_PLIST)
    if _update_android_gradle(root, ANDROID_GRADLE, version, build):
        changed.append(ANDROID_GRADLE)
    if _update_windows_csproj(root, WINDOWS_CSPROJ, version, build):
        changed.append(WINDOWS_CSPROJ)
    return version, build, changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Verify all version locations match Shared/version.json without writing")
    mode.add_argument("--print", choices=("version", "build"), help="Print version or build from Shared/version.json")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.print:
            version, build = load_version_source(args.root)
            print(version if args.print == "version" else build)
            return 0
        if args.check:
            version, build, errors = check_all(args.root)
            if errors:
                print("\n".join(errors), file=sys.stderr)
                return 1
            print(f"Checked 4 platform version locations against {VERSION_SOURCE}: {version} (build {build})")
            return 0
        version, build, changed = sync_all(args.root)
        if changed:
            print(f"Synced {len(changed)} file(s) from {VERSION_SOURCE} ({version} build {build}): {', '.join(changed)}")
        else:
            print(f"All 4 platform version locations already match {VERSION_SOURCE} ({version} build {build})")
        return 0
    except (ValueError, OSError) as exc:
        print(f"Version source error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
