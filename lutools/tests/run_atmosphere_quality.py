#!/usr/bin/env python3
"""Render the fixed external atmosphere set; measurements do not replace visual review."""
import argparse
import hashlib
import io
import json
import subprocess
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont, ImageOps


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contact_sheet(images, labels, path, tile=(550, 400), columns=3, credit=""):
    rows = (len(images) + columns - 1) // columns
    canvas = Image.new("RGB", (tile[0] * columns, (tile[1] + 32) * rows + 44), "#222222")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=17)
    for index, (image, label) in enumerate(zip(images, labels)):
        x, y = (index % columns) * tile[0], (index // columns) * (tile[1] + 32)
        copy = image.copy()
        copy.thumbnail(tile, Image.Resampling.LANCZOS)
        canvas.paste(copy, (x + (tile[0] - copy.width) // 2, y + 32 + (tile[1] - copy.height) // 2))
        draw.text((x + 6, y + 7), label, fill="white", font=font)
    draw.text((8, canvas.height - 34), "Processing test / modified: " + credit, fill="white", font=font)
    canvas.save(path)


def region(image, rectangle):
    x, y, width, height = rectangle
    return image.crop((round(x * image.width), round(y * image.height),
                       round((x + width) * image.width), round((y + height) * image.height)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("fixtures") / "atmosphere-v1-quality.json")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"status": "MEASURED_NOT_VISUALLY_REVIEWED", "manifest_sha256": sha256(args.manifest),
              "probe_sha256": sha256(args.probe), "cases": [],
              "measurement_space": "display-encoded RGB8 view of native 16-bit PNG; real images are unpaired"}
    for case in manifest["cases"]:
        if args.only and case["id"] not in args.only:
            continue
        source = args.assets / case["input"]["path"]
        if sha256(source) != case["input"]["sha256"]:
            raise ValueError("source hash mismatch: " + case["id"])
        output = args.output / case["id"]
        output.mkdir(exist_ok=True)
        width = height = 0
        kind = "raw"
        if case["input"]["kind"] == "raster":
            with Image.open(source) as decoded:
                profile = decoded.info.get("icc_profile")
                picture = ImageOps.exif_transpose(decoded).convert("RGB")
                if profile:
                    picture = ImageCms.profileToProfile(picture, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                                       ImageCms.createProfile("sRGB"), outputMode="RGB")
                width, height = picture.size
                source = output / "source.rgb8"
                source.write_bytes(picture.tobytes())
            kind = "rgb"
        rendered = []
        result = {"id": case["id"], "source_sha256": case["input"]["sha256"], "variants": []}
        for variant in manifest["variants"]:
            destination = output / (variant["id"] + ".png")
            command = [str(args.probe), kind, str(source), str(width), str(height),
                       str(variant["clarity"]), str(variant["dehaze"]), str(destination), "0"]
            start = time.monotonic()
            with (output / (variant["id"] + ".log")).open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            with Image.open(destination) as image:
                rendered.append(image.convert("RGB"))
            result["variants"].append({"id": variant["id"], "seconds": time.monotonic() - start,
                                       "png_sha256": sha256(destination), "dimensions": rendered[-1].size,
                                       "regions": []})
            print(case["id"], variant["id"], "rendered", flush=True)
        labels = [v["id"] for v in manifest["variants"]]
        credit = case.get("credit", "raw.pixls.us") + " | " + case["license"]
        contact_sheet(rendered, labels, output / "overview.png", credit=credit)
        for item in case["regions"]:
            views = [region(image, item["rect"]) for image in rendered]
            baseline = np.asarray(views[0], dtype=np.float32)
            crops = []
            for index, view in enumerate(views):
                values = np.asarray(view, dtype=np.float32)
                y = values[..., 0] * .2126 + values[..., 1] * .7152 + values[..., 2] * .0722
                gradient_std = float(np.std(np.diff(y, axis=1)))
                result["variants"][index]["regions"].append({"id": item["id"],
                    "mean_rgb": values.mean(axis=(0, 1)).tolist(),
                    "delta_rgb_mean": (values - baseline).mean(axis=(0, 1)).tolist(),
                    "delta_abs_mean": float(np.abs(values - baseline).mean()),
                    "black_fraction": float(np.mean(np.max(values, axis=2) <= 1)),
                    "white_fraction": float(np.mean(np.min(values, axis=2) >= 254)),
                    "luma_horizontal_difference_std": gradient_std})
                # 100% 中央裁切不缩放，保留细纹/噪声，而非放大缩略图。
                w, h = min(360, view.width), min(300, view.height)
                left, top = (view.width - w) // 2, (view.height - h) // 2
                crops.append(view.crop((left, top, left + w, top + h)))
            contact_sheet(crops, labels, output / (item["id"] + "-100pct.png"),
                          tile=(360, 300), columns=3, credit=credit)
        report["cases"].append(result)
        (args.output / "measurements.json").write_text(json.dumps(report, indent=2) + "\n")
        if kind == "rgb":
            source.unlink()


if __name__ == "__main__":
    main()
