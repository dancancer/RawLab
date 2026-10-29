#!/usr/bin/env python3
"""Fetch pinned public originals or verify them read-only before/after native tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

MANIFEST = Path(__file__).with_name("public-fixtures.json")
XMP = b"http://ns.adobe.com/hdr-gain-map/1.0/"
ISO = b"urn:iso:std:iso:ts:21496:-1"


def inspect(path, fixture):
    before = path.stat()
    data = path.read_bytes()
    assert len(data) == fixture["bytes"], f"{path}: size mismatch"
    assert hashlib.sha256(data).hexdigest() == fixture["sha256"], f"{path}: SHA-256 mismatch"
    assert fixture["modified"] is False and fixture["source_page"] and fixture["author"] and fixture["license_url"]
    assert fixture["protocol"] == "ultra_hdr_xmp" and XMP in data and ISO not in data, f"{path}: expected XMP-only original"
    assert data[:2] == b"\xff\xd8", f"{path}: not JPEG"
    offset, dimensions = 2, None
    while offset + 4 <= len(data):
        assert data[offset] == 255, f"{path}: invalid marker"
        while data[offset] == 255:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xD9, 0xDA):
            break
        length = int.from_bytes(data[offset:offset + 2], "big")
        assert length >= 2 and offset + length <= len(data), f"{path}: invalid segment"
        if marker in (0xC0, 0xC1, 0xC2):
            dimensions = (int.from_bytes(data[offset + 5:offset + 7], "big"),
                          int.from_bytes(data[offset + 3:offset + 5], "big"))
            break
        offset += length
    assert dimensions == (fixture["width"], fixture["height"]), f"{path}: dimensions mismatch"
    after = path.stat()
    assert (before.st_size, before.st_mtime_ns, before.st_ino) == (after.st_size, after.st_mtime_ns, after.st_ino)
    return {"sha256": fixture["sha256"], "bytes": after.st_size, "mtime_ns": after.st_mtime_ns, "inode": after.st_ino}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--fetch", action="store_true", help="Download only missing files; never replace an existing original")
    parser.add_argument("--test-binary", type=Path, help="Run the production hdr_image_tests external-input checks")
    parser.add_argument("--result", type=Path)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    records = []
    if args.fetch:
        args.directory.mkdir(parents=True, exist_ok=True)
    for fixture in manifest["fixtures"]:
        name = fixture["filename"]
        assert Path(name).name == name and name.endswith(".jpg"), "Unsafe fixture name"
        path = args.directory / name
        if not path.exists() and args.fetch:
            request = urllib.request.Request(fixture["url"], headers={"User-Agent": "RawLab-HDR-fixture-validation/1"})
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read(fixture["bytes"] + 1)
            assert len(data) == fixture["bytes"] and hashlib.sha256(data).hexdigest() == fixture["sha256"], f"{name}: untrusted download"
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=args.directory, prefix=".hdr-", delete=False) as output:
                    temporary = Path(output.name)
                    output.write(data)
                temporary.chmod(0o444)
                # A concurrent collector must not overwrite a newly created original.
                os.link(temporary, path)
            finally:
                if temporary:
                    temporary.unlink(missing_ok=True)
        before = inspect(path, fixture)
        if args.test_binary:
            subprocess.run([str(args.test_binary.resolve()), str(path.resolve())], check=True)
        after = inspect(path, fixture)
        assert before == after, f"{name}: original changed during validation"
        records.append({**fixture, "verified": after, "original_unchanged": True,
                        "production_preview_checked": args.test_binary is not None})
    result = {"manifest_sha256": hashlib.sha256(MANIFEST.read_bytes()).hexdigest(), "fixtures": records,
              "scope": "Source integrity and production preview decode; not FINAL, A08 or physical HDR acceptance"}
    encoded = json.dumps(result, indent=2)
    if args.result:
        args.result.write_text(encoded + "\n")
    print(f"PASS {len(records)} pinned Android originals, XMP protocol, dimensions, attribution and unchanged source hashes")


if __name__ == "__main__":
    main()
