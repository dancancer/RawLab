"""Prepare explicitly interpreted LUTs; redistribution permission remains unconfirmed."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

import numpy as np
import PyOpenColorIO as ocio

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from lutools.lutprep.color import apply_processor, srgb_decode, srgb_encode
from lutools.lutprep.pipeline import file_processor


def gamma24_adapter(source):
    processor = file_processor(source, "linear")

    def evaluate(display_srgb):
        # 相同的 BT.709/D65 原色只转换传递函数，避免无意义的 XYZ 矩阵往返。
        encoded = np.maximum(srgb_decode(display_srgb), 0) ** (1 / 2.4)
        result = apply_processor(processor, encoded)
        return np.clip(srgb_encode(np.maximum(result, 0) ** 2.4), 0, 1)

    return evaluate


def write_display_cube(path, evaluate, size):
    axis = np.linspace(0, 1, size)
    g, r = np.meshgrid(axis, axis, indexing="ij")
    plane = np.stack([r.ravel(), g.ravel(), np.zeros(size * size)], axis=1)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write('TITLE "RawLab adapted display look"\n#Gamma:sRGB to sRGB\n'
                     '#Gamut:ITU-R BT.709 to ITU-R BT.709\n')
        stream.write(f"LUT_3D_SIZE {size}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n")
        for b in axis:
            plane[:, 2] = b
            values = evaluate(plane)
            if values.shape != plane.shape or not np.isfinite(values).all():
                raise ValueError("Adapter produced invalid RGB values")
            np.savetxt(stream, values, fmt="%.9g")


def measure_error(evaluate, path):
    rng = np.random.default_rng(20261016)
    axis = np.linspace(0, 1, 17)
    cube = np.stack(np.meshgrid(axis, axis, axis, indexing="ij"), axis=-1).reshape(-1, 3)
    gray = np.repeat(np.linspace(0, 1, 1025)[:, None], 3, axis=1)
    samples = np.concatenate([cube, gray, rng.random((8192, 3))])
    actual = apply_processor(file_processor(path, "linear"), samples)
    error = np.abs(actual - evaluate(samples))
    return {"samples": len(samples), "max": float(error.max()), "mean": float(error.mean()),
            "p99": float(np.quantile(error, .99)), "measurement": "sampled display-sRGB channel error; not a global bound"}


def prepare(source_root, output, force=False):
    source_root, output = source_root.resolve(), output.resolve()
    if source_root.is_relative_to(output) or output.is_relative_to(source_root):
        raise ValueError("Source directory must remain separate and read-only")
    plan = json.loads((ROOT / "Shared/bundled-look-plan.json").read_text())
    audit = json.loads((ROOT / plan["sourceAudit"]).read_text())
    hashes = {entry["path"]: entry["sha256"] for entry in audit["entries"]}
    base = json.loads((ROOT / "Shared/BundledLooks/catalog.json").read_text())[:1]
    output.mkdir(parents=True, exist_ok=True)
    catalog, reports = list(base), []
    with tempfile.TemporaryDirectory(prefix="rawlab-adapt-", dir=output) as temporary:
        temporary = Path(temporary)
        for look in plan["looks"]:
            source = source_root / look["source"]
            raw = source.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest != hashes[look["source"]]:
                raise ValueError(f"Source changed: {look['source']}; audit again before adapting")
            name = look["id"] + ".cube"
            if (output / name).exists() and not force:
                raise FileExistsError(f"Destination exists: {name}; use --force")
            target = temporary / name
            if look["adaptation"] == "camera-gamma24":
                evaluate = gamma24_adapter(source)
                for size in (33, 65):
                    write_display_cube(target, evaluate, size)
                    error = measure_error(evaluate, target)
                    if error["max"] <= .025 and error["p99"] <= .002:
                        break
                else:
                    raise ValueError(f"Adapter exceeds max 0.025 / p99 0.002 sampled error: {look['source']}: {error}")
                report = {"size": size, "resampled": True, "error": error}
            elif look["adaptation"] == "gmic-rgb-creative":
                header = ("# RawLab creative RGB interpretation, not an assertion about the original transfer.\n"
                          "#Gamma:sRGB to sRGB\n#Gamut:ITU-R BT.709 to ITU-R BT.709\n")
                target.write_bytes(header.encode() + raw)
                report = {"size": 13, "resampled": False, "sourcePayloadByteIdentical": True}
            else:
                raise ValueError(f"Unknown adaptation: {look['adaptation']}")
            metadata = {"source": look["source"], "sourceSha256": digest,
                        "adaptation": look["adaptation"], "interpretation": plan["notes"][look["adaptation"]],
                        "redistribution": "unconfirmed", "ocioVersion": ocio.__version__, **report}
            with target.open("a", encoding="utf-8") as stream:
                stream.write("\n#RawLab:" + json.dumps(metadata, separators=(",", ":")) + "\n")
            catalog.append({"id": look["id"], "name": look["name"], "fileName": name,
                            "artworkName": look["artworkName"], "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                            "input": "neutral display-sRGB / BT.709 / D65 / full range",
                            "output": "display-sRGB / BT.709 / D65 / full range",
                            "license": "UNCONFIRMED - redistribution permission not verified", "source": look["source"]})
            reports.append({"id": look["id"], **metadata})
        for look in catalog[1:]:
            os.replace(temporary / look["fileName"], output / look["fileName"])
    (output / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
    (output / "adaptation-report.json").write_text(json.dumps(reports, indent=2) + "\n")
    return reports


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.force), indent=2))
