#!/usr/bin/env python3
"""Check effective Android Debug CPU-denoise flags in compile_commands.json."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex


REPO = Path(__file__).resolve().parents[2]
NUMERICAL_TEST = str(REPO / "lutools/tests/wavelet_denoise_tests.cpp")
TARGETS = {"sony2fuji_core", "wavelib", "opencv_core", "opencv_imgproc"}
REQUIRED = {
    str(REPO / "lutools/src/core/wavelet_denoise.cpp"): "sony2fuji_core",
    "core/wavelib/wavelib.c": "wavelib",
    "_deps/rawlab_wavelib-src/src/wtmath.c": "wavelib",
    "_deps/rawlab_opencv-src/modules/core/src/matrix.cpp": "opencv_core",
    "_deps/rawlab_opencv-src/modules/imgproc/src/box_filter.dispatch.cpp": "opencv_imgproc",
    "_deps/rawlab_opencv-src/modules/imgproc/src/filter.dispatch.cpp": "opencv_imgproc",
}
OPTIMIZATION = re.compile(r"-O(?:[0-3sgz]|fast)?$")
UNSAFE_MATH = {"-Ofast", "-ffast-math", "-funsafe-math-optimizations",
               "-fassociative-math", "-freciprocal-math", "-ffinite-math-only",
               "-fno-honor-nans", "-fno-honor-infinities", "-fno-signed-zeros",
               "-fapprox-func", "-fno-trapping-math", "-menable-no-nans",
               "-menable-no-infs", "-mreassociate"}
SAFE_FP_VALUES = {
    "-ffp-model": {"precise", "strict"},
    "-ffp-contract": {"on", "off"},
    "-fdenormal-fp-math": {"ieee", "ieee,ieee"},
    "-fdenormal-fp-math-f32": {"ieee", "ieee,ieee"},
    "-mrecip": {"none"},
}
OPAQUE_OPTIONS = ("-Xclang", "-mllvm", "--config")
DEPENDENCIES = TARGETS - {"sony2fuji_core"}


def arguments(entry):
    return entry["arguments"] if "arguments" in entry else shlex.split(entry["command"])


def effective_optimization(tokens):
    return next((token for token in reversed(tokens) if OPTIMIZATION.fullmatch(token)), "-O0")


def normalized_path(entry, path):
    directory = entry.get("directory", "")
    if not os.path.isabs(directory):
        raise ValueError("Compile object requires an absolute directory")
    return os.path.normpath(os.path.join(directory, path))


def output(entry):
    tokens = arguments(entry)
    outputs = []
    for index, token in enumerate(tokens):
        if token == "-o":
            if index + 1 == len(tokens):
                raise ValueError(f"Missing object output after -o: {entry['file']}")
            outputs.append(tokens[index + 1])
    explicit = entry.get("output")
    if explicit and outputs:
        if normalized_path(entry, explicit) != normalized_path(entry, outputs[-1]):
            raise ValueError(f"Conflicting object output: {entry['file']}")
    return explicit or (outputs[-1] if outputs else None)


def target(entry):
    match = re.search(r"(?:^|/)CMakeFiles/([^/]+)\.dir/", output(entry) or "")
    return match[1] if match else None


def unsafe_math_options(tokens):
    # Reject unsafe options even if a later flag might partially override them.
    return {token for token in tokens if token in UNSAFE_MATH or
            (token.partition("=")[0] in SAFE_FP_VALUES and
             token.partition("=")[2] not in SAFE_FP_VALUES[token.partition("=")[0]])}


def validate(entries):
    errors = []
    counts = dict.fromkeys(TARGETS, 0)
    for source, expected_target in sorted(REQUIRED.items()):
        matches = [entry for entry in entries
                   if normalized_path(entry, entry["file"]) == normalized_path(entry, source)]
        if len(matches) != 1:
            errors.append(f"Expected exactly one {source}, found {len(matches)}")
        elif target(matches[0]) != expected_target:
            errors.append(f"Wrong or missing target for {source}")
    for entry in entries:
        tokens = arguments(entry)
        name = target(entry)
        if name not in TARGETS:
            continue
        counts[name] += 1
        if any(token.startswith("@") for token in tokens):
            errors.append(f"Unexpanded response file: {entry['file']}")
        if any(token == option or token.startswith(option + "=")
               for token in tokens for option in OPAQUE_OPTIONS):
            errors.append(f"Uninspected compiler option: {entry['file']}")
        effective = effective_optimization(tokens)
        if effective != "-O3":
            errors.append(f"{name}: effective {effective}, expected -O3: {entry['file']}")
        unsafe = unsafe_math_options(tokens)
        if unsafe:
            errors.append(f"Unsafe math {sorted(unsafe)}: {entry['file']}")
    for name, count in sorted(counts.items()):
        if count == 0:
            errors.append(f"Missing target {name}")
    return counts, errors


def compile_objects(entries):
    objects = {}
    for entry in entries:
        destination = output(entry)
        if not destination or not entry.get("file"):
            raise ValueError("Compile object requires directory, source and output")
        key = tuple(normalized_path(entry, path) for path in (entry["file"], destination))
        if key in objects:
            raise ValueError(f"Duplicate compile object: {key}")
        objects[key] = entry
    return objects


def compare_commands(before, after):
    old, new = compile_objects(before), compile_objects(after)
    changed = [key for key in sorted(old.keys() & new.keys())
               if arguments(old[key]) != arguments(new[key]) or
               os.path.normpath(old[key]["directory"]) != os.path.normpath(new[key]["directory"])]
    added, removed = sorted(new.keys() - old.keys()), sorted(old.keys() - new.keys())
    counts, errors = validate(after)
    for key in changed:
        previous, current = arguments(old[key]), arguments(new[key])
        only_o3_added = any(token == "-O3" and previous == current[:index] + current[index + 1:]
                           for index, token in enumerate(current))
        same_directory = os.path.normpath(old[key]["directory"]) == os.path.normpath(new[key]["directory"])
        if target(new[key]) not in DEPENDENCIES or not only_o3_added or not same_directory:
            errors.append(f"Unexpected compile change: {key}")
    numerical_tests = [key for key in added
                       if key[0] == NUMERICAL_TEST and target(new[key]) == "wavelet_denoise_tests"]
    if len(numerical_tests) > 1:
        errors.append(f"Multiple numerical-test objects added: {len(numerical_tests)}")
    for key in added:
        if key not in numerical_tests:
            errors.append(f"Unexpected added object: {key}")
    errors.extend(f"Removed compile object: {key}" for key in removed)
    describe = lambda keys: [{"file": source, "output": destination} for source, destination in keys]
    return {
        "before_records": len(old), "before_sources": len({key[0] for key in old}),
        "after_records": len(new), "after_sources": len({key[0] for key in new}),
        "changed_objects": len(changed),
        "changed_targets": dict(sorted(Counter(target(new[key]) or "<unknown>" for key in changed).items())),
        "added_objects": describe(added), "removed_objects": describe(removed),
        "policy_counts": counts, "errors": errors,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("databases", nargs="*", type=Path)
    parser.add_argument("--compare", nargs=2, type=Path, metavar=("BEFORE", "AFTER"),
                        help="Compare every source/output object; allow only the CPU optimization and numerical test target")
    options = parser.parse_args()
    if options.compare:
        if options.databases:
            parser.error("Use either --compare or database checks")
        try:
            report = compare_commands(*(json.loads(path.read_text()) for path in options.compare))
        except (ValueError, KeyError, TypeError, OSError) as error:
            parser.error(str(error))
        print(json.dumps(report, indent=2, sort_keys=True))
        return int(bool(report["errors"]))
    if not options.databases:
        parser.error("Pass at least one compilation database")
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
