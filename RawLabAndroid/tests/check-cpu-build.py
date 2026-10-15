#!/usr/bin/env python3
"""Check effective Android Debug CPU-denoise flags in compile_commands.json."""

import argparse
import json
from pathlib import Path
import re
import shlex


TARGETS = {"sony2fuji_core", "wavelib", "opencv_core", "opencv_imgproc"}
REQUIRED = {
    "/lutools/src/core/wavelet_denoise.cpp": "sony2fuji_core",
    "/core/wavelib/wavelib.c": "wavelib",
    "/src/wtmath.c": "wavelib",
    "/modules/core/src/matrix.cpp": "opencv_core",
    "/modules/imgproc/src/box_filter.dispatch.cpp": "opencv_imgproc",
    "/modules/imgproc/src/filter.dispatch.cpp": "opencv_imgproc",
}
OPTIMIZATION = re.compile(r"-O(?:[0-3sgz]|fast)?$")
UNSAFE_MATH = {"-Ofast", "-ffast-math", "-funsafe-math-optimizations",
               "-fassociative-math", "-freciprocal-math", "-ffp-model=fast"}


def arguments(entry):
    return entry["arguments"] if "arguments" in entry else shlex.split(entry["command"])


def effective_optimization(tokens):
    return next((token for token in reversed(tokens) if OPTIMIZATION.fullmatch(token)), "-O0")


def target(entry):
    tokens = arguments(entry)
    output = entry.get("output")
    if output is None and "-o" in tokens:
        output = tokens[tokens.index("-o") + 1]
    match = re.search(r"(?:^|/)CMakeFiles/([^/]+)\.dir/", output or "")
    return match[1] if match else None


def validate(entries):
    errors = []
    counts = dict.fromkeys(TARGETS, 0)
    for suffix in sorted(REQUIRED):
        matches = [entry for entry in entries if entry["file"].endswith(suffix)]
        if len(matches) != 1:
            errors.append(f"Expected exactly one {suffix}, found {len(matches)}")
        elif target(matches[0]) != REQUIRED[suffix]:
            errors.append(f"Wrong or missing target for {suffix}")
    for entry in entries:
        tokens = arguments(entry)
        name = target(entry)
        if name not in TARGETS:
            continue
        counts[name] += 1
        if any(token.startswith("@") for token in tokens):
            errors.append(f"Unexpanded response file: {entry['file']}")
        effective = effective_optimization(tokens)
        if effective != "-O3":
            errors.append(f"{name}: effective {effective}, expected -O3: {entry['file']}")
        unsafe = UNSAFE_MATH.intersection(tokens)
        if unsafe:
            errors.append(f"Unsafe math {sorted(unsafe)}: {entry['file']}")
    for name, count in sorted(counts.items()):
        if count == 0:
            errors.append(f"Missing target {name}")
    return counts, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("databases", nargs="+", type=Path)
    options = parser.parse_args()
    failed = False
    for path in options.databases:
        counts, errors = validate(json.loads(path.read_text()))
        print(f"{path}: {json.dumps(counts, sort_keys=True)}")
        for error in errors[:8]:
            print(f"FAIL: {error}")
        if len(errors) > 8:
            print(f"FAIL: {len(errors) - 8} additional errors")
        failed |= bool(errors)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
