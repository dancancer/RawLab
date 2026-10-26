#!/usr/bin/env python3
"""Locate the provisioned noncommercial model and fetch the pinned desktop runtime."""
import argparse
import hashlib
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


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("macos", "windows"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    cache = Path(os.environ.get("RAWLAB_AI_SHARED_CACHE", Path.home() / ".cache/rawlab-ci"))
    model = Path(os.environ.get("RAWLAB_DUALDN_MODEL_DIR", cache / "ai-models" / MANIFEST / "complete"))
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
