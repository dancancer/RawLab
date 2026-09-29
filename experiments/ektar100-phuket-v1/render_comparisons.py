"""Render comparison images through RawLab's generic C++ LUT applicator."""

import argparse
import json
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont

import color_lut as color


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def read_pfm(path):
    with path.open("rb") as file:
        if file.readline().strip() != b"PF":
            raise ValueError("Expected RGB PFM")
        w, h = map(int, file.readline().split())
        if float(file.readline()) != -1:
            raise ValueError("Expected little-endian PFM")
        data = np.fromfile(file, dtype="<f4")
    return np.flipud(data.reshape(h, w, 3)).copy()


def save_rgb(rgb, path):
    image = Image.fromarray(np.uint8(np.round(np.clip(rgb, 0, 1) * 255)))
    image.save(path, quality=95, subsampling=0, icc_profile=ICC)


def make_row(paths, title, output):
    cell_w, cell_h = 480, 360
    canvas = Image.new("RGB", (cell_w * len(paths), cell_h + 68), "#ededed")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 19)
    draw.text((12, 8), title, font=font, fill="#161616")
    for index, (label, path) in enumerate(paths):
        with Image.open(path) as original:
            image = original.copy()
        image.thumbnail((cell_w - 8, cell_h - 8), Image.Resampling.LANCZOS)
        x = index * cell_w
        draw.text((x + 12, 37), label, font=font, fill="#161616")
        canvas.paste(image, (x + (cell_w - image.width) // 2, 68 + (cell_h - image.height) // 2))
    canvas.save(output, quality=95, subsampling=0, icc_profile=ICC)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=Path, default=Path("/tmp/rawtools-ektar-probe"))
    args = parser.parse_args()
    cache = HERE / ".cache"
    cache.mkdir(exist_ok=True)
    output = HERE / "comparisons"
    output.mkdir(exist_ok=True)
    new_path = HERE / "EKTAR_100_Phuket_v1_FLog2_FGamut_65.cube"
    luts = {
        "PROVIA": ROOT / "lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube",
        "Velvia": ROOT / "lutools/flog-2-new/FLog2_to_Velvia_65grid_V.1.00.cube",
        "EKTAR-v1": new_path,
    }
    tables = {key: color.read_cube(path) for key, path in luts.items()}
    delivered = tables["EKTAR-v1"]
    if delivered.shape != (65, 65, 65, 3) or delivered.min() < 0 or delivered.max() > 1:
        raise ValueError("Delivered CUBE must be 65-grid with bounded display RGB values")
    raws = sorted((ROOT / "lutools/examples").glob("*.ARW")) + sorted((ROOT / "lutools/test-assets").glob("*.ARW"))
    raws += sorted((ROOT / "lutools/examples").glob("*.DNG"))
    results, rows = [], []
    for raw in raws:
        prefix = cache / raw.stem
        log_path = prefix.with_suffix(".log.pfm")
        metadata_path = prefix.with_suffix(".txt")
        if not log_path.exists() or not metadata_path.exists():
            result = subprocess.run([str(args.probe), "raw", str(raw), str(prefix), "1400"],
                                    check=True, capture_output=True, text=True)
            metadata_path.write_text(result.stdout)
        linear = read_pfm(prefix.with_suffix(".linear.pfm"))
        encoded = read_pfm(log_path)
        neutral = color.srgb_encode(color.tone_curve(linear))
        neutral_path = output / f"{raw.stem}-Neutral.jpg"
        save_rgb(neutral, neutral_path)
        images = [("Neutral", neutral_path)]
        record = {"raw": str(raw.relative_to(ROOT)), "development": metadata_path.read_text(), "renders": {}}
        for label, lut_path in luts.items():
            target = cache / f"{raw.stem}-{label}.pfm"
            subprocess.run([str(args.probe), "apply", str(log_path), str(lut_path), str(target)], check=True)
            rendered = read_pfm(target)
            if not np.isfinite(rendered).all():
                raise ValueError("Non-finite RAW render")
            sampled = encoded[::4, ::4]
            python_render = color.apply_cube(tables[label], sampled)
            error = float(np.abs(python_render - rendered[::4, ::4]).max())
            if error > 0.00003:
                raise ValueError(f"C++/Python LUT mismatch: {error}")
            image_path = output / f"{raw.stem}-{label}.jpg"
            save_rgb(rendered, image_path)
            images.append((label, image_path))
            record["renders"][label] = {
                "cpp_python_max_abs_error": error,
                "pixels_any_channel_le_0": float(np.any(rendered <= 0, axis=-1).mean()),
                "pixels_any_channel_ge_1": float(np.any(rendered >= 1, axis=-1).mean()),
                "range": [float(rendered.min()), float(rendered.max())],
            }
        row = output / f"{raw.stem}-comparison.jpg"
        make_row(images, f"{raw.name} | Same camera WB and scene exposure | Independent, unpaired RAW", row)
        results.append(record)
        rows.append(row)
        print(f"Rendered and checked {raw.name}", flush=True)
    for start in range(0, len(rows), 3):
        selected = [Image.open(path) for path in rows[start:start + 3]]
        sheet = Image.new("RGB", (selected[0].width, sum(im.height for im in selected)))
        y = 0
        for image in selected:
            sheet.paste(image, (0, y))
            y += image.height
            image.close()
        sheet.save(output / f"comparison-sheet-{start // 3 + 1}.jpg", quality=94, icc_profile=ICC)
    values = np.geomspace(.18 * 2 ** -7, .18 * 2 ** 7, 241)
    gray = np.repeat(values[:, None], 3, axis=-1)
    log = color.scene_to_log(gray)
    gray_out = color.apply_cube(tables["EKTAR-v1"], log)
    delta = np.diff(gray_out, axis=0)
    # Sub-micro code-value deviations near black are below 1/3000 of an 8-bit step.
    if delta.min() < -1e-6:
        raise ValueError("Baked LUT gray ramp exceeds monotonicity tolerance")
    rng = np.random.default_rng(100)
    scene = rng.uniform(.05, 1, (12000, 3)) * np.exp2(rng.uniform(-3, 2, (12000, 1)))
    samples = color.scene_to_log(scene)
    error = np.abs(color.apply_cube(tables["EKTAR-v1"], samples) - color.ektar(samples))
    stops = np.arange(-6, 7)
    gray_stops = color.scene_to_log(np.repeat((.18 * 2. ** stops)[:, None], 3, axis=-1))
    curve_reference = {label: color.apply_cube(table, gray_stops).mean(axis=-1).tolist()
                       for label, table in tables.items()}
    report = {
        "parameters": color.PARAMETERS, "raw_count": len(results), "raws": results,
        "lut_size": delivered.shape[0], "points": int(delivered.size // 3),
        "gray_ramp_min_step": float(delta.min()),
        "gray_ramp_monotonicity_tolerance": 1e-6,
        "gray_ramp_max_channel_spread": float(np.ptp(gray_out, axis=-1).max()),
        "interpolation_direct_error_p99_max": np.quantile(error, [.99, 1]).tolist(),
        "gray_curve_stops_relative_to_18_percent": stops.tolist(),
        "gray_curve_display_encoded_reference": curve_reference,
        "claims": "Technical validity and unrelated RAW stress tests only; no paired film matching accuracy measurement.",
    }
    (HERE / "validation.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
