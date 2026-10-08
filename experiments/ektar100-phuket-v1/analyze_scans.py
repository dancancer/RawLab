# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.4.1", "pillow==12.1.0", "tifffile==2026.3.3", "imagecodecs"]
# ///
"""Read-only scan analysis; only reduced, ICC-converted previews are written."""

import argparse
import ctypes as ct
import ctypes.util
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont
import tifffile


def to_srgb(rgb, profile):
    lib = ct.CDLL(ctypes.util.find_library("lcms2") or "/opt/homebrew/lib/liblcms2.dylib")
    signatures = {
        "cmsOpenProfileFromMem": ([ct.c_void_p, ct.c_uint32], ct.c_void_p),
        "cmsCreate_sRGBProfile": ([], ct.c_void_p),
        "cmsCreateTransform": ([ct.c_void_p, ct.c_uint32, ct.c_void_p, ct.c_uint32,
                                ct.c_uint32, ct.c_uint32], ct.c_void_p),
        "cmsDoTransform": ([ct.c_void_p, ct.c_void_p, ct.c_void_p, ct.c_uint32], None),
        "cmsDeleteTransform": ([ct.c_void_p], None),
        "cmsCloseProfile": ([ct.c_void_p], ct.c_int),
    }
    for name, (args, result) in signatures.items():
        getattr(lib, name).argtypes = args
        getattr(lib, name).restype = result
    blob = ct.create_string_buffer(profile)
    source = lib.cmsOpenProfileFromMem(blob, len(profile))
    dest = lib.cmsCreate_sRGBProfile()
    if not source or not dest:
        raise ValueError("Cannot open embedded RGB ICC profile")
    # LittleCMS TYPE_RGB_FLT: floating point, RGB space, 3 channels, 4-byte samples.
    fmt = (1 << 22) | (4 << 16) | (3 << 3) | 4
    transform = lib.cmsCreateTransform(source, fmt, dest, fmt, 1, 0)
    try:
        if not transform:
            raise ValueError("Cannot construct ICC transform")
        rgb = np.ascontiguousarray(rgb, dtype=np.float32)
        output = np.empty_like(rgb)
        lib.cmsDoTransform(transform, rgb.ctypes.data, output.ctypes.data, rgb.size // 3)
        return output
    finally:
        if transform:
            lib.cmsDeleteTransform(transform)
        lib.cmsCloseProfile(source)
        lib.cmsCloseProfile(dest)


def save_rgb(rgb, path):
    image = Image.fromarray(np.uint8(np.round(np.clip(rgb, 0, 1) * 255)))
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    image.save(path, quality=94, icc_profile=profile)


def contact_sheet(paths, output, columns=6, size=240):
    rows = (len(paths) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * size, rows * (size + 28)), "#eeeeee")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
    for i, path in enumerate(paths):
        with Image.open(path) as original:
            thumb = original.copy()
        thumb.thumbnail((size - 10, size - 10), Image.Resampling.LANCZOS)
        x, y = (i % columns) * size, (i // columns) * (size + 28)
        canvas.paste(thumb, (x + (size - thumb.width) // 2, y + (size - thumb.height) // 2))
        draw.text((x + 8, y + size + 3), path.stem, font=font, fill="#202020")
    canvas.save(output, quality=94, icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(args.source.resolve()):
        raise ValueError("Analysis output must be outside the original scan directory")
    args.output.mkdir(parents=True, exist_ok=True)
    thumbs = args.output / "thumbnails"
    thumbs.mkdir(exist_ok=True)
    records = []
    paths = sorted(args.source.glob("*.tif"), key=lambda p: int(p.stem.split("-")[-1]))
    if not paths:
        raise ValueError("No TIFF scans found")
    for index, path in enumerate(paths):
        with tifffile.TiffFile(path) as tif:
            page = tif.pages[0]
            profile = page.tags[34675].value
            profile_name = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(profile))).strip()
            orientation = page.tags.get(274)
            if orientation and orientation.value != 1:
                raise ValueError(f"Unexpected TIFF orientation: {path}")
            data = page.asarray()
            if data.dtype != np.uint16 or data.ndim != 3 or data.shape[-1] != 3:
                raise ValueError(f"Expected 16-bit RGB scan: {path}")
            h, w = data.shape[:2]
            stride = max(1, int(np.ceil(max(h, w) / 800)))
            sampled = data[::stride, ::stride].astype(np.float32) / 65535
            del data
            rgb = to_srgb(sampled, profile)
        target = thumbs / f"{path.stem}.jpg"
        save_rgb(rgb, target)
        # Border exclusion is for descriptive statistics, not a fitted color mapping.
        dy, dx = max(1, rgb.shape[0] // 20), max(1, rgb.shape[1] // 20)
        crop = np.clip(rgb[dy:-dy, dx:-dx], 0, 1)
        luminance = crop @ np.array([0.2126, 0.7152, 0.0722])
        maximum, minimum = crop.max(axis=-1), crop.min(axis=-1)
        saturation = (maximum - minimum) / np.maximum(maximum, 1e-8)
        records.append({
            "file": path.name, "width": w, "height": h, "bits": 16, "profile": profile_name,
            "encoded_luma_p01_p10_p50_p90_p99": np.quantile(luminance, [.01, .1, .5, .9, .99]).tolist(),
            "hsv_saturation_p50_p90": np.quantile(saturation, [.5, .9]).tolist(),
            "srgb_out_of_range_pixel_fraction": float(np.any((rgb < 0) | (rgb > 1), axis=-1).mean()),
        })
        print(f"{index + 1}/{len(paths)} {path.name}: {profile_name}", flush=True)
    report = {
        "source": str(args.source), "count": len(records),
        "method": "16-bit TIFF sampled before LittleCMS float ICC conversion; relative colorimetric to sRGB. Statistics exclude outer 5% per edge. No fitting or exposure normalization.",
        "images": records,
    }
    (args.output / "scan-analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    thumbnails = [thumbs / f"{p.stem}.jpg" for p in paths]
    for start in range(0, len(paths), 24):
        contact_sheet(thumbnails[start:start + 24], args.output / f"scans-{start + 1:02d}-{min(start + 24, len(paths)):02d}.jpg")


if __name__ == "__main__":
    main()
