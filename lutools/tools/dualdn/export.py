#!/usr/bin/env python3
"""Export the pinned DualDn weights; this tool is not part of the app runtime."""

import argparse
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import time
import types

import numpy as np
import torch

SOURCE_REVISION = "7ec5f6a21c04321beb0d3297d6e9ac5f50635555"
WEIGHTS_SHA256 = "9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d"
SOURCE_SHA256 = {
    "archs/DualDn_arch.py": "ebba640b4a8c893f43eef563ebb758d2683ef5d8a41ef8242023ab807b9b0997",
    "archs/backbone/restormer.py": "4f609a7be01e9227496fa73e9a8aadbad3636441ce16abdacddacfbc355cf697",
    "utils/pipeline.py": "6068df2a2256cb29d495e696d04a4ae69e8771f52915eff31234485b0d878852",
    "LICENSE": "566b84c659cfed1d2e6ca015e86c0db07e68b70a607161885fcccbad8ae27a5f",
}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_source(source):
    for relative, expected in SOURCE_SHA256.items():
        if sha256(source / relative) != expected:
            raise ValueError(f"Source SHA-256 mismatch: {relative}")


def validate_tile_size(size):
    if size < 16 or size % 8:
        raise ValueError("Tile size must be at least 16 and divisible by 8")


def import_file(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_model(source, weights):
    verify_source(source)
    if sha256(weights) != WEIGHTS_SHA256:
        raise ValueError("Weights SHA-256 mismatch")
    restormer = import_file("dualdn_restormer", source / "archs/backbone/restormer.py")
    pipeline = import_file("dualdn_pipeline", source / "utils/pipeline.py")
    # 只加载固定文件中的两个定义，避免上游训练注册器引入无关依赖；不改 forward。
    path = source / "archs/DualDn_arch.py"
    tree = ast.parse(path.read_text())
    definitions = []
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name in {"Concat", "DualDn"}:
            node.decorator_list = []
            definitions.append(node)
    module = types.ModuleType("dualdn_arch")
    module.__dict__.update(torch=torch, nn=torch.nn, Restormer=restormer.Restormer,
                           run_pipeline=pipeline.run_pipeline)
    exec(compile(ast.Module(body=definitions, type_ignores=[]), str(path), "exec"),
         module.__dict__)
    model = module.DualDn(with_noise_map=True, c=64).eval()
    state = torch.load(weights, map_location="cpu", weights_only=True)["params"]
    model.load_state_dict(state, strict=True)
    if len(state) != 420 or sum(p.numel() for p in model.parameters()) != 53048212:
        raise ValueError("Unexpected DualDn checkpoint structure")
    return model, pipeline


class RawHead(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.fuse = model.nm_fuse1
        self.backbone = model.backbone1
        self.output = model.conv_out1

    def forward(self, packed_raw, k, b):
        raw = packed_raw.clamp(min=1e-8)
        noise = (k * raw + b).clamp(min=1e-7).sqrt()
        return self.output(self.backbone(self.fuse([raw, noise]))) + raw


class RgbHead(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.fuse = model.nm_fuse2
        self.backbone = model.backbone2
        self.output = model.conv_out2

    def forward(self, skip_rgb, noise_rgb):
        return self.output(self.backbone(self.fuse([skip_rgb, noise_rgb]))) + skip_rgb


class OfficialISP(torch.nn.Module):
    def __init__(self, pipeline, size):
        super().__init__()
        self.pipeline = pipeline
        mask = torch.tensor([[0, 1], [3, 2]], dtype=torch.float32).repeat(size // 2, size // 2)
        self.register_buffer("color_mask", mask[None, None])

    def forward(self, mosaic, wb, camera_to_xyz):
        metadata = dict(color_mask=self.color_mask, wb_matrix=wb,
                        rgb_xyz_matrix=camera_to_xyz, color_desc="RGBG", ref="D65",
                        gamma_type="Rec709", demosaic_type="AHD", alpha=0)
        return self.pipeline.run_pipeline(mosaic, metadata, "normal", "tone_mapping")


def compare(actual, expected, name):
    difference = np.abs(actual - expected)
    result = {"max_abs": float(difference.max()), "mean_abs": float(difference.mean())}
    if not np.isfinite(actual).all() or result["max_abs"] > 1e-4 or result["mean_abs"] > 1e-5:
        raise ValueError(f"CPU parity failed for {name}: {result}")
    return result


def export_graph(name, model, inputs, input_names, output_name, output):
    import onnx
    import onnxruntime as ort

    path = output / f"{name}.onnx"
    start = time.monotonic()
    torch.onnx.export(model, inputs, str(path), input_names=input_names,
                      output_names=[output_name], opset_version=17,
                      do_constant_folding=True, dynamo=False)
    graph = onnx.load(path)
    onnx.checker.check_model(graph)
    options = ort.SessionOptions()
    options.intra_op_num_threads = torch.get_num_threads()
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(path), sess_options=options,
                                  providers=["CPUExecutionProvider"])
    if name == "raw":
        second = (inputs[0] * 0.01, inputs[1] * 0.01, inputs[2] * 0.001)
    elif name == "isp":
        second = (inputs[0] * 0.23,
                  inputs[1] * torch.tensor([0.6, 1.2, 1.8, 1.2]),
                  inputs[2] * 0.9 + torch.eye(3).reshape(1, 1, 3, 3) * 0.1)
    else:
        second = (inputs[0] * 0.23, inputs[1] * 0.1)
    checks = []
    for index, variant in enumerate([inputs, second]):
        with torch.inference_mode():
            expected = model(*variant).numpy()
        feed = {key: value.numpy() for key, value in zip(input_names, variant)}
        actual = session.run([output_name], feed)[0]
        checks.append(compare(actual, expected, f"{name}/{index}"))
        if index == 0:
            for key, value in feed.items():
                value.astype("<f4").tofile(output / f"{name}-{key}.f32")
            expected.astype("<f4").tofile(output / f"{name}-expected.f32")
    print(json.dumps({"graph": name, "seconds": time.monotonic() - start,
                      "cpu_parity": checks}), flush=True)
    return {"file": path.name, "sha256": sha256(path), "bytes": path.stat().st_size,
            "inputs": [{"name": key, "shape": list(value.shape)}
                       for key, value in zip(input_names, inputs)],
            "output": {"name": output_name, "shape": list(expected.shape)},
            "cpu_parity": checks}


def split_reference_check(model, pipeline):
    """Compare the graph boundaries against the untouched upstream full forward."""
    generator = torch.Generator().manual_seed(214)
    mosaic = torch.rand((1, 1, 64, 64), generator=generator) * 1.2 + 1e-8
    wb = torch.tensor([2.1, 1.0, 1.55, 1.0]).reshape(1, 1, 1, 4)
    matrix = torch.tensor([[0.7, 0.2, 0.1], [0.15, 0.75, 0.1],
                           [0.04, 0.2, 0.76]]).reshape(1, 1, 3, 3)
    k, b = torch.tensor([0.0018241977770013236]), torch.tensor([5.150549402363373e-6])
    isp = OfficialISP(pipeline, 64)
    with torch.inference_mode():
        raw, rgb = model(mosaic, isp.color_mask, wb, matrix, k=k, sigma=b)
        raw_split = torch.nn.functional.pixel_shuffle(
            RawHead(model)(torch.nn.functional.pixel_unshuffle(mosaic, 2), k, b), 2)
        rgb_split = RgbHead(model)(isp(raw_split, wb, matrix),
                                  isp((k * mosaic + b).clamp(min=1e-7).sqrt(), wb, matrix))
    return {"raw": compare(raw_split.numpy(), raw.numpy(), "split/raw"),
            "rgb": compare(rgb_split.numpy(), rgb.numpy(), "split/rgb")}


def build(args):
    import onnxruntime as ort

    validate_tile_size(args.tile_size)
    if args.output.exists():
        raise ValueError("Output already exists; choose a new versioned directory")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(args.threads)
    model, pipeline = load_model(args.source, args.weights)
    split_check = split_reference_check(model, pipeline)
    size = args.tile_size
    generator = torch.Generator().manual_seed(20261022)
    raw = torch.rand((1, 4, size, size), generator=generator) * 1.4 - 0.1
    skip = torch.rand((1, 3, size, size), generator=generator) * 1.2 - 0.05
    noise = torch.rand((1, 3, size, size), generator=generator) * 0.15
    k, b = torch.tensor([0.0018241977770013236]), torch.tensor([5.150549402363373e-6])
    mosaic = torch.rand((1, 1, size, size), generator=generator) * 1.2
    wb = torch.tensor([2.1, 1.0, 1.55, 1.0]).reshape(1, 1, 1, 4)
    matrix = torch.tensor([[0.7, 0.2, 0.1], [0.15, 0.75, 0.1],
                           [0.04, 0.2, 0.76]]).reshape(1, 1, 3, 3)
    with tempfile.TemporaryDirectory(prefix=".dualdn-", dir=args.output.parent) as temporary:
        output = Path(temporary)
        graphs = {}
        graphs["raw"] = export_graph("raw", RawHead(model), (raw, k, b),
                                     ["packed_raw", "k", "b"], "denoised_packed", output)
        graphs["isp"] = export_graph("isp", OfficialISP(pipeline, size), (mosaic, wb, matrix),
                                     ["mosaic", "wb", "camera_to_xyz"], "encoded_rgb", output)
        graphs["rgb"] = export_graph("rgb", RgbHead(model), (skip, noise),
                                     ["skip_rgb", "noise_rgb"], "denoised_rgb", output)
        shutil.copyfile(args.source / "LICENSE", output / "DualDn-LICENSE.txt")
        manifest = {
            "format_version": 1, "model_id": "dualdn-big-restormer-v1",
            "protocol": "rawlab-dualdn-v1", "source_revision": SOURCE_REVISION,
            "source_url": f"https://github.com/OpenImagingLab/DualDn/tree/{SOURCE_REVISION}",
            "weights_sha256": WEIGHTS_SHA256, "source_sha256": SOURCE_SHA256,
            "tile_size": size, "production_geometry": size == 640,
            "raw_core": 384, "raw_halo": 128, "rgb_core": 512, "rgb_halo": 64,
            "packed_order": ["R", "G_top", "G_bottom", "B"],
            "input_floor": 1e-8, "variance_floor": 1e-7, "sigma_semantics": "variance",
            "isp": {"demosaic": "AHD", "gamma": "Rec709", "reference": "D65",
                    "alpha": 0, "bgu": False},
            "torch_version": torch.__version__, "onnxruntime_version": ort.__version__,
            "split_reference_parity": split_check, "graphs": graphs,
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # .f32 是开发用的原生回放输入；安装器只复制清单内模型和许可。
        shutil.move(str(output), args.output)
    print(json.dumps({"output": str(args.output), "split_reference_parity": split_check}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tile-size", type=int, default=640)
    parser.add_argument("--threads", type=int, default=6)
    build(parser.parse_args())
