"""Read-only CUBE inventory. Data validity does not establish a color contract or license."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import shlex
import struct


def inspect(path, root):
    raw = path.read_bytes()
    size, title = None, None
    domains = {"DOMAIN_MIN": None, "DOMAIN_MAX": None}
    declarations, values = {}, []
    for number, line in enumerate(raw.decode("utf-8-sig").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            key, separator, value = line[1:].partition(":")
            if separator and key.strip().lower() in ("gamma", "gamut", "inputtransfer", "outputtransfer"):
                declarations[key.strip()] = value.strip()
            continue
        parts = shlex.split(line, comments=True)
        if not parts:
            continue
        key = parts[0]
        if key == "TITLE":
            title = " ".join(parts[1:])
        elif key == "LUT_3D_SIZE":
            if size is not None or len(parts) != 2:
                raise ValueError(f"{path.name}:{number}: duplicate or invalid size")
            size = int(parts[1])
        elif key in domains:
            if domains[key] is not None or len(parts) != 4:
                raise ValueError(f"{path.name}:{number}: invalid domain")
            domains[key] = list(map(float, parts[1:]))
        else:
            if len(parts) != 3:
                raise ValueError(f"{path.name}:{number}: expected an RGB triple")
            values.append(tuple(map(float, parts)))
    if size is None or size < 2 or len(values) != size ** 3:
        raise ValueError(f"{path.name}: incomplete 3D table")
    numbers = [v for row in values for v in row]
    if not all(math.isfinite(v) for v in numbers + sum((v or [] for v in domains.values()), [])):
        raise ValueError(f"{path.name}: nonfinite values")
    minimum = domains["DOMAIN_MIN"] or [0, 0, 0]
    maximum = domains["DOMAIN_MAX"] or [1, 1, 1]
    if any(a >= b for a, b in zip(minimum, maximum)):
        raise ValueError(f"{path.name}: empty domain")
    semantic = hashlib.sha256(json.dumps([size, domains], sort_keys=True).encode())
    for value in numbers:
        semantic.update(struct.pack("<d", 0.0 if value == 0 else value))
    return {"path": path.relative_to(root).as_posix(), "bytes": len(raw), "title": title,
            "size": size, "rows": len(values), "domainMin": domains["DOMAIN_MIN"],
            "domainMax": domains["DOMAIN_MAX"], "finite": True,
            "minimum": [min(row[c] for row in values) for c in range(3)],
            "maximum": [max(row[c] for row in values) for c in range(3)],
            "sha256": hashlib.sha256(raw).hexdigest(), "semanticSha256": semantic.hexdigest(),
            "declarations": declarations}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    entries = [inspect(path, args.source) for path in sorted(args.source.rglob("*.cube"))]
    groups = {}
    for entry in entries:
        groups.setdefault(entry["semanticSha256"], []).append(entry["path"])
    print(json.dumps({"files": len(entries), "duplicates": [g for g in groups.values() if len(g) > 1],
                      "entries": entries}, indent=2))
