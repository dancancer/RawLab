#!/usr/bin/env python3
"""Add the pinned real-sRGB Restormer graph to a DualDn model bundle."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

import numpy as np
import torch
from export import sha256
from export_coreml import convert_head, model_files, compare

SOURCE_REVISION = "b19fa6e7104cb946ac8c5d6368117962ed0e751b"
WEIGHTS_SHA256 = "4cae18bed8a291b9a5deeeab48756bbe6f61fcf7f31a4cca0969b24608601387"
LICENSE_SHA256 = "50fdf21f3caa7c42c51e0145d6cdb70a4f0d456955797d1f94de14c640a2c702"
SOURCE_SHA256 = {
    "basicsr/models/archs/restormer_arch.py": "3be243fa3c8e2cb2c9459eeac062b04d6084dbcc328292dae1c3e52ba6f7434a",
    "Denoising/Options/RealDenoising_Restormer.yml": "697bf6402c58d22e1f7314f1f87fbed2a5de6f5f912ae9dcc96bba203b3b5b32",
}

def load_model(source, weights):
    for name, expected in SOURCE_SHA256.items():
        if sha256(source / name) != expected:
            raise ValueError("Restormer source SHA-256 mismatch: " + name)
    if sha256(weights) != WEIGHTS_SHA256:
        raise ValueError("Restormer weights SHA-256 mismatch")
    spec = importlib.util.spec_from_file_location("rawlab_restormer", source / "basicsr/models/archs/restormer_arch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    model = module.Restormer(inp_channels=3, out_channels=3, dim=48, num_blocks=[4,6,6,8],
        num_refinement_blocks=4, heads=[1,2,4,8], ffn_expansion_factor=2.66,
        bias=False, LayerNorm_type="BiasFree", dual_pixel_task=False).eval()
    model.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True)["params"], strict=True)
    return model

def build(args):
    import onnx
    import onnxruntime as ort
    if args.output.exists():
        raise ValueError("Choose a new output directory")
    if sha256(args.license) != LICENSE_SHA256:
        raise ValueError("Expected the v1.0 model's original Academic Public License")
    torch.set_num_threads(args.threads)
    model = load_model(args.source, args.weights)
    manifest = json.loads((args.package / "manifest.json").read_text())
    if manifest["protocol"] != "rawlab-dualdn-v1" or manifest["tile_size"] != 640:
        raise ValueError("Expected the production DualDn bundle")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".restormer-", dir=args.output.parent) as temporary:
        output = Path(temporary) / "bundle"
        shutil.copytree(args.package, output)
        generator = torch.Generator().manual_seed(20261023)
        inputs = torch.rand((1,3,640,640), generator=generator) * .6 + .1
        path = output / "blind_rgb.onnx"
        with torch.inference_mode():
            torch.onnx.export(model, (inputs,), str(path), input_names=["encoded_rgb"],
                output_names=["denoised_rgb"], opset_version=17, do_constant_folding=True, dynamo=False)
        onnx.checker.check_model(onnx.load(path))
        options = ort.SessionOptions(); options.intra_op_num_threads = args.threads; options.inter_op_num_threads = 1
        session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
        checks = []
        for index, value in enumerate((inputs, inputs * .1)):
            with torch.inference_mode(): expected = model(value).numpy()
            actual = session.run(["denoised_rgb"], {"encoded_rgb":value.numpy()})[0]
            checks.append(compare(actual, expected))
            if index == 0:
                value.numpy().astype("<f4").tofile(output / "blind_rgb-encoded_rgb.f32")
                expected.astype("<f4").tofile(output / "blind_rgb-expected.f32")
        del session
        graph = {"model_id":"restormer-real-srgb-v1", "protocol":"rawlab-scene-rgb-v1",
            "source_revision":SOURCE_REVISION, "weights_sha256":WEIGHTS_SHA256,
            "weights_url":"https://github.com/swz30/Restormer/releases/download/v1.0/real_denoising.pth",
            "tile_size":640, "core":512, "halo":64, "input":"encoded_rgb", "output":"denoised_rgb",
            "file":path.name, "bytes":path.stat().st_size, "sha256":sha256(path), "cpu_parity":checks,
            "license_file":"Restormer-LICENSE.txt", "license_sha256":LICENSE_SHA256}
        print(json.dumps({"restormer_onnx":checks}), flush=True)
        if args.coreml:
            import coremltools as ct
            if ct.__version__ != "9.0": raise ValueError("Expected coremltools 9.0")
            native = convert_head(model, (inputs,), ["encoded_rgb"], "denoised_rgb", output / "blind_rgb.mlmodelc")
            checks = []
            for value in (inputs, inputs * .1):
                with torch.inference_mode(): expected = model(value).numpy()
                checks.append(compare(native.predict({"encoded_rgb":value.numpy()})["denoised_rgb"], expected))
            graph["coreml"] = {**model_files(output / "blind_rgb.mlmodelc"), "precision":"float32", "parity":checks}
            print(json.dumps({"restormer_coreml":checks}), flush=True)
        shutil.copyfile(args.license, output / "Restormer-LICENSE.txt")
        manifest["blind_rgb"] = graph
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
        shutil.move(str(output), args.output)
    print(json.dumps({"output":str(args.output)}), flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("package", "source", "weights", "license", "output"):
        parser.add_argument("--"+name, type=Path, required=True)
    parser.add_argument("--threads", type=int, default=6)
    parser.add_argument("--coreml", action="store_true")
    build(parser.parse_args())
