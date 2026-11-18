#!/usr/bin/env python3
"""Read the single LibRaw dependency manifest for CMake, Python, and shell callers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import sys


DEFAULT_MANIFEST = Path(__file__).with_name("manifest.json")


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError(f"Unsupported LibRaw manifest schema_version: {data.get('schema_version')!r}")
    return data


def shell_exports(data: dict) -> str:
    libraw = data["libraw"]
    cmake_wrap = data["libraw_cmake"]
    scalars = {
        "RAWLAB_LIBRAW_VERSION": libraw["version"],
        "RAWLAB_LIBRAW_TAG": libraw["tag"],
        "RAWLAB_LIBRAW_ARCHIVE": libraw["archive"],
        "RAWLAB_LIBRAW_DIRECTORY": libraw["directory"],
        "RAWLAB_LIBRAW_URL": libraw["url"],
        "RAWLAB_LIBRAW_SHA256": libraw["sha256"],
        "RAWLAB_LIBRAW_CMAKE_REVISION": cmake_wrap["revision"],
        "RAWLAB_LIBRAW_CMAKE_ARCHIVE": cmake_wrap["archive"],
        "RAWLAB_LIBRAW_CMAKE_DIRECTORY": cmake_wrap["directory"],
        "RAWLAB_LIBRAW_CMAKE_URL": cmake_wrap["url"],
        "RAWLAB_LIBRAW_CMAKE_SHA256": cmake_wrap["sha256"],
    }
    lines = [f"{key}={shlex.quote(str(value))}" for key, value in scalars.items()]
    licenses = " ".join(shlex.quote(str(item)) for item in libraw["license_files"])
    lines.append(f"RAWLAB_LIBRAW_LICENSE_FILES=({licenses})")
    return "\n".join(lines)


def lookup_field(data: dict, dotted_key: str):
    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            raise KeyError(f"Unknown manifest field: {dotted_key}")
        current = current[part]
    return current


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST, help="Path to LibRaw manifest JSON")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--shell", action="store_true", help="Emit shell variable assignments")
    mode.add_argument("--field", help="Print a single dotted field (e.g. libraw.version)")
    args = parser.parse_args(argv)

    data = load_manifest(args.manifest)
    if args.shell:
        print(shell_exports(data))
        return 0
    value = lookup_field(data, args.field)
    if isinstance(value, list):
        for item in value:
            print(item)
    else:
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
