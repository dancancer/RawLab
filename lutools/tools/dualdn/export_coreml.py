#!/usr/bin/env python3
"""Add native float32 Core ML heads to a pinned DualDn ONNX package on macOS."""

import argparse
import json
from pathlib import Path
import shutil
import tempfile
import time

import numpy as np
import torch

from export import RawHead, RgbHead, SOURCE_REVISION, WEIGHTS_SHA256, load_model, sha256


def model_files(directory):
    files = []
    if directory.is_symlink():
        raise ValueError("Core ML directory cannot be a symlink")
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError("Core ML resources cannot contain symlinks")
        if path.is_file():
            files.append({"path": path.relative_to(directory).as_posix(),
                          "sha256": sha256(path), "bytes": path.stat().st_size})
    if not files:
        raise ValueError("Core ML model is empty")
    if len(files) > 64 or sum(item["bytes"] for item in files) > 512 * 1024 * 1024:
        raise ValueError("Core ML model exceeds package limits")
    return {"directory": directory.name, "files": files}


def convert_head(head, inputs, input_names, output_name, destination):
    import coremltools as ct

    with torch.inference_mode():
        traced = torch.jit.trace(head.eval(), inputs, check_trace=False)
    model = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                       inputs=[ct.TensorType(name=name, shape=value.shape, dtype=np.float32)
                               for name, value in zip(input_names, inputs)],
                       outputs=[ct.TensorType(name=output_name, dtype=np.float32)],
                       compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    shutil.copytree(model.get_compiled_model_path(), destination)
    return model


def compare(actual, expected):
    difference = np.abs(actual - expected)
    result = {"max_abs": float(difference.max()), "mean_abs": float(difference.mean())}
    if not np.isfinite(actual).all() or result["max_abs"] > 3e-4 or result["mean_abs"] > 2e-5:
        raise ValueError(f"Core ML parity failed: {result}")
    return result


def build(args):
    import coremltools as ct

    if ct.__version__ != "9.0":
        raise ValueError("This converter requires coremltools 9.0")
    if args.output.exists():
        raise ValueError("Output already exists; choose a new versioned directory")
    manifest = json.loads((args.package / "manifest.json").read_text())
    if (manifest["source_revision"] != SOURCE_REVISION or manifest["weights_sha256"] != WEIGHTS_SHA256 or
            manifest["protocol"] != "rawlab-dualdn-v1" or manifest["tile_size"] != 640):
        raise ValueError("Expected the pinned 640-pixel DualDn package")
    torch.set_num_threads(args.threads)
    model, _ = load_model(args.source, args.weights)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".dualdn-coreml-", dir=args.output.parent) as temporary:
        output = Path(temporary)
        for kind in ("raw", "isp", "rgb"):
            graph = manifest["graphs"][kind]
            source = args.package / f"{kind}.onnx"
            if (graph["file"] != source.name or sha256(source) != graph["sha256"] or
                    source.stat().st_size != graph["bytes"]):
                raise ValueError("Base ONNX package is not intact")
            shutil.copyfile(source, output / source.name)
        shutil.copyfile(args.source / "LICENSE", output / "DualDn-LICENSE.txt")
        native_manifest = {"format": "mlmodelc", "precision": "float32", "coremltools_version": ct.__version__,
                           "torch_version": torch.__version__, "minimum_macos": "14.0"}
        generator = torch.Generator().manual_seed(20261023)
        for kind, head in (("raw", RawHead(model)), ("rgb", RgbHead(model))):
            graph = manifest["graphs"][kind]
            names = [item["name"] for item in graph["inputs"]]
            inputs = []
            for item in graph["inputs"]:
                reference = args.package / f"{kind}-{item['name']}.f32"
                if reference.exists():
                    value = torch.from_numpy(np.fromfile(reference, dtype="<f4").reshape(item["shape"]))
                elif item["name"] == "k":
                    value = torch.tensor([0.0018241977770013236])
                elif item["name"] == "b":
                    value = torch.tensor([5.150549402363373e-6])
                else:
                    value = torch.rand(item["shape"], generator=generator) * 1.2 - 0.05
                inputs.append(value)
            inputs = tuple(inputs)
            started = time.monotonic()
            native = convert_head(head, inputs, names, graph["output"]["name"], output / f"{kind}.mlmodelc")
            second = (inputs[0] * .01, inputs[1] * .01, inputs[2] * .001) if kind == "raw" else (inputs[0] * .23, inputs[1] * .1)
            checks = []
            for variant in (inputs, second):
                with torch.inference_mode():
                    expected = head(*variant).numpy()
                actual = native.predict({name: value.numpy() for name, value in zip(names, variant)})[graph["output"]["name"]]
                checks.append(compare(actual, expected))
            native_manifest[kind] = {**model_files(output / f"{kind}.mlmodelc"), "parity": checks}
            print(json.dumps({"graph": kind, "seconds": time.monotonic() - started, "parity": checks}), flush=True)
            del native
        manifest["coreml"] = native_manifest
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for fixture in args.package.glob("*.f32"):
            shutil.copyfile(fixture, output / fixture.name)
        shutil.move(str(output), args.output)
    print(json.dumps({"output": str(args.output)}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=6)
    build(parser.parse_args())
