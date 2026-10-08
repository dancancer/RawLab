"""Visual diagnostics, not a measured color-chart reproduction test."""

import colorsys
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont

import color_lut as color


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
report = json.loads((HERE / "validation.json").read_text())
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 19)
small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
canvas = Image.new("RGB", (1440, 1050), "#f5f5f5")
draw = ImageDraw.Draw(canvas)
draw.text((32, 18), "EKTAR 100 Phuket v1 | Tone and gradient checks", font=font, fill="#161616")
draw.text((32, 47), "Synthetic inputs. These are not paired film measurements or a calibrated ColorChecker test.", font=small, fill="#444444")
colors = {"Neutral": "#777777", "PROVIA": "#167443", "Velvia": "#7b4397", "EKTAR-v1": "#d13c25"}
tables = {
    "PROVIA": color.read_cube(ROOT / "lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"),
    "Velvia": color.read_cube(ROOT / "lutools/flog-2-new/FLog2_to_Velvia_65grid_V.1.00.cube"),
    "EKTAR-v1": color.read_cube(HERE / "EKTAR_100_Phuket_v1_FLog2_FGamut_65.cube"),
}
stops = np.linspace(-6, 6, 1000)
linear_gray = np.repeat((.18 * 2 ** stops)[:, None], 3, axis=-1)
gray_log = color.scene_to_log(linear_gray)
left, top, width, height = 80, 115, 1180, 340
for i in range(7):
    x = left + width * i / 6
    draw.line((x, top, x, top + height), fill="#d7d7d7")
    draw.text((x - 10, top + height + 8), str(i * 2 - 6), font=small, fill="#333333")
for i in range(6):
    y = top + height * i / 5
    draw.line((left, y, left + width, y), fill="#d7d7d7")
    draw.text((35, y - 9), f"{1-i/5:.1f}", font=small, fill="#333333")
for i, (name, stroke) in enumerate(colors.items()):
    rgb = color.neutral(gray_log) if name == "Neutral" else color.apply_cube(tables[name], gray_log)
    points = [(left + j * width / (len(stops) - 1), top + height * (1 - value))
              for j, value in enumerate(rgb.mean(axis=-1))]
    draw.line(points, fill=stroke, width=3)
    draw.text((100 + 280 * i, 82), name, font=font, fill=stroke)
draw.text((420, 490), "Exposure stops relative to 18% gray; output is sRGB encoded", font=small, fill="#444444")
gradient_width = 1120
exposure = np.repeat((.18 * 2 ** np.linspace(-8, 8, gradient_width))[:, None], 3, axis=-1)
hue = np.array([colorsys.hsv_to_rgb(h, .65, .5) for h in np.linspace(0, 1, gradient_width)])
gray_samples, hue_samples = color.scene_to_log(exposure), color.scene_to_log(hue)
draw.text((235, 538), "Top: -8 to +8 EV neutral ramp. Bottom: continuous synthetic hue sweep.", font=small, fill="#444444")
for i, name in enumerate(colors):
    y = 573 + i * 104
    transform = color.neutral if name == "Neutral" else lambda value: color.apply_cube(tables[name], value)
    gray_rgb, hue_rgb = transform(gray_samples), transform(hue_samples)
    for offset, rgb in [(0, gray_rgb), (41, hue_rgb)]:
        image = Image.fromarray(np.uint8(np.round(np.clip(rgb[None], 0, 1) * 255)))
        canvas.paste(image.resize((gradient_width, 38)), (235, y + offset))
    draw.text((32, y + 27), name, font=font, fill=colors[name])
draw.text((32, 1013), "65^3 CUBE | Trilinear interpolation | No grain, halation or local contrast added", font=small, fill="#444444")
canvas.save(HERE / "curves-and-gradients.png", icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
