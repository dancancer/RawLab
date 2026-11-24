"""CLI --analyze, --sample, and --print-transfer contract and parity tests."""
import argparse
import importlib.util
import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

# Load rawlab_agent.py from the skill directory when present for direct <0.2% reference parity,
# and also include a self-contained fallback reference for CI environments without ~/.gemini.
_SKILL_AGENT = pathlib.Path.home() / ".gemini" / "config" / "skills" / "rawlab-photo-agent" / "scripts" / "rawlab_agent.py"
if _SKILL_AGENT.is_file():
    _spec = importlib.util.spec_from_file_location("rawlab_agent_ref", _SKILL_AGENT)
    assert _spec and _spec.loader
    _mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    _ref_analyze_png = _mod.analyze_png
    _ref_parse_sample_arg = _mod.parse_sample_arg
else:
    import colorsys
    import math

    _HSL_CHANNELS = [
        ("red", 0.0), ("orange", 30.0), ("yellow", 60.0), ("green", 120.0),
        ("aqua", 180.0), ("blue", 240.0), ("purple", 270.0), ("magenta", 300.0),
    ]

    def _ref_parse_sample_arg(raw_arg):
        parts = [p.strip() for p in raw_arg.split(",")]
        x, y = float(parts[0]), float(parts[1])
        label = parts[2] if len(parts) == 3 and parts[2] else f"point_{x:.2f}_{y:.2f}"
        return (x, y, label)

    def _paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)

    def _decode_png(path):
        data = pathlib.Path(path).read_bytes()
        pos = 8
        width = height = bit_depth = color_type = 0
        idat = []
        while pos + 8 <= len(data):
            length = struct.unpack_from(">I", data, pos)[0]
            ctype = data[pos + 4 : pos + 8]
            payload = data[pos + 8 : pos + 8 + length]
            pos += 12 + length
            if ctype == b"IHDR":
                width, height, bit_depth, color_type, *_ = struct.unpack(">IIBBBBB", payload)
            elif ctype == b"IDAT":
                idat.append(payload)
            elif ctype == b"IEND":
                break
        channels = {0: 1, 2: 3, 6: 4}[color_type]
        bpp = channels * (bit_depth // 8)
        row_bytes = width * bpp
        raw = zlib.decompress(b"".join(idat))
        rows, prev, off = [], bytearray(row_bytes), 0
        mv = memoryview(raw)
        for _ in range(height):
            ft = mv[off]
            cur = bytearray(mv[off + 1 : off + 1 + row_bytes])
            off += 1 + row_bytes
            if ft == 1:
                for i in range(bpp, row_bytes): cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
            elif ft == 2:
                for i in range(row_bytes): cur[i] = (cur[i] + prev[i]) & 0xFF
            elif ft == 3:
                for i in range(row_bytes): cur[i] = (cur[i] + (((cur[i - bpp] if i >= bpp else 0) + prev[i]) >> 1)) & 0xFF
            elif ft == 4:
                for i in range(row_bytes): cur[i] = (cur[i] + _paeth(cur[i - bpp] if i >= bpp else 0, prev[i], prev[i - bpp] if i >= bpp else 0)) & 0xFF
            rows.append(cur)
            prev = cur
        return width, height, bit_depth, channels, rows

    def _ref_analyze_png(path, sample_points=None):
        width, height, bit_depth, channels, rows = _decode_png(path)
        bpp = channels * (bit_depth // 8)
        stride = max(1, max(width, height) // 360)
        lumas, sats = [], []
        blacks = shadows = midtones = lights = highlights = 0
        shadow_crush = white_blowout = clip_r = clip_g = clip_b = clip_any = melting_sat = low_sat = neutral_count = 0
        nr = ng = nb = luma_sum = sat_sum = 0.0
        ch = {n: [0.0, 0.0, 0.0, 0.0, 0.0] for n, _ in _HSL_CHANNELS}
        total = 0
        for yp in range(0, height, stride):
            row = rows[yp]
            for xp in range(0, width, stride):
                off = xp * bpp
                if bit_depth == 16:
                    r, g, b = (((row[off] << 8) | row[off + 1]) / 65535.0, ((row[off + 2] << 8) | row[off + 3]) / 65535.0, ((row[off + 4] << 8) | row[off + 5]) / 65535.0)
                else:
                    r, g, b = (row[off] / 255.0, row[off + 1] / 255.0, row[off + 2] / 255.0)
                total += 1
                lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma_sum += lum
                lumas.append(lum)
                if lum < 0.10: blacks += 1
                elif lum < 0.35: shadows += 1
                elif lum < 0.65: midtones += 1
                elif lum < 0.90: lights += 1
                else: highlights += 1
                if max(r, g, b) <= 1.0 / 255.0: shadow_crush += 1
                if min(r, g, b) >= 254.0 / 255.0: white_blowout += 1
                hr, hg, hb = r >= 0.996, g >= 0.996, b >= 0.996
                clip_r += int(hr); clip_g += int(hg); clip_b += int(hb); clip_any += int(hr or hg or hb)
                hn, sv, vv = colorsys.rgb_to_hsv(r, g, b)
                sat_sum += sv; sats.append(sv)
                if sv < 0.15: low_sat += 1
                if sv > 0.85 and vv > 0.35: melting_sat += 1
                if 0.18 <= lum <= 0.82 and sv <= 0.35:
                    neutral_count += 1; nr += r; ng += g; nb += b
                if sv >= 0.08:
                    hd = (hn * 360.0) % 360.0
                    cname = min(_HSL_CHANNELS, key=lambda c: min(abs(hd - c[1]), 360.0 - abs(hd - c[1])))[0]
                    rad = math.radians(hd)
                    st = ch[cname]; st[0] += 1; st[1] += math.sin(rad); st[2] += math.cos(rad); st[3] += sv; st[4] += vv
        lumas.sort(); sats.sort()
        pct = lambda a, q: round(a[min(len(a) - 1, max(0, int(round(q * (len(a) - 1)))))], 4)
        share = lambda c: round((c * 100.0) / total, 2)
        rog = round(nr / ng, 4) if ng > 1e-6 else 1.0
        bog = round(nb / ng, 4) if ng > 1e-6 else 1.0
        cast = ("insufficient_neutrals" if neutral_count < max(20, total * 0.01) else
                "warm_yellow_amber" if rog > 1.07 and bog < 0.94 else
                "cool_blue" if bog > 1.07 and rog < 0.95 else
                "green_cast" if rog < 0.94 and bog < 0.94 else
                "magenta_cast" if rog > 1.05 and bog > 1.05 else "balanced")
        hsl_out = {}
        for n, _ in _HSL_CHANNELS:
            st = ch[n]; cov = round((st[0] * 100.0) / total, 2)
            if cov >= 0.2:
                hsl_out[n] = {"coverage_pct": cov, "mean_hue_deg": round(math.degrees(math.atan2(st[1], st[2])) % 360.0, 1),
                              "mean_sat_pct": round((st[3] / st[0]) * 100.0, 1), "mean_brightness_pct": round((st[4] / st[0]) * 100.0, 1)}
        samples_out = []
        for sx, sy, lbl in sample_points or []:
            cx = min(width - 1, max(0, int(round(sx * (width - 1)))))
            cy = min(height - 1, max(0, int(round(sy * (height - 1)))))
            sr = sg = sb = 0.0; sc = 0
            for yy in range(max(0, cy - 4), min(height, cy + 5)):
                row = rows[yy]
                for xx in range(max(0, cx - 4), min(width, cx + 5)):
                    off = xx * bpp
                    if bit_depth == 16:
                        pr, pg, pb = (((row[off] << 8) | row[off + 1]) / 65535.0, ((row[off + 2] << 8) | row[off + 3]) / 65535.0, ((row[off + 4] << 8) | row[off + 5]) / 65535.0)
                    else:
                        pr, pg, pb = (row[off] / 255.0, row[off + 1] / 255.0, row[off + 2] / 255.0)
                    sr += pr; sg += pg; sb += pb; sc += 1
            mr, mg, mb = sr / sc, sg / sc, sb / sc
            mh, ms, mv = colorsys.rgb_to_hsv(mr, mg, mb)
            hd = round((mh * 360.0) % 360.0, 1)
            samples_out.append({
                "label": lbl, "norm_coord": [round(sx, 4), round(sy, 4)], "pixel_coord": [cx, cy],
                "rgb_8bit": [int(round(mr * 255)), int(round(mg * 255)), int(round(mb * 255))],
                "hsb": {"h_deg": hd, "s_pct": round(ms * 100.0, 1), "b_pct": round(mv * 100.0, 1)},
                "hsl_channel": min(_HSL_CHANNELS, key=lambda c: min(abs(hd - c[1]), 360.0 - abs(hd - c[1])))[0],
            })
        p05, p95 = pct(lumas, 0.05), pct(lumas, 0.95)
        return {
            "dimensions": {"width": width, "height": height, "sampled_pixels": total},
            "luma_zones": {
                "blacks_0_10_pct": share(blacks), "shadows_10_35_pct": share(shadows),
                "midtones_35_65_pct": share(midtones), "lights_65_90_pct": share(lights),
                "highlights_90_100_pct": share(highlights), "mean_luma_0_1": round(luma_sum / total, 4),
                "percentiles_0_1": {"p01": pct(lumas, 0.01), "p05": p05, "p25": pct(lumas, 0.25),
                                    "p50": pct(lumas, 0.50), "p75": pct(lumas, 0.75), "p95": p95, "p99": pct(lumas, 0.99)},
                "percentiles_0_255": {"p01": int(round(pct(lumas, 0.01) * 255)), "p05": int(round(p05 * 255)),
                                      "p50": int(round(pct(lumas, 0.50) * 255)), "p95": int(round(p95 * 255)),
                                      "p99": int(round(pct(lumas, 0.99) * 255))},
                "dynamic_spread_p95_minus_p05": round(p95 - p05, 4),
            },
            "clipping": {"shadow_crush_pct": share(shadow_crush), "white_blowout_pct": share(white_blowout),
                         "channel_clip_high_pct": {"any": share(clip_any), "r": share(clip_r), "g": share(clip_g), "b": share(clip_b)}},
            "color_balance": {"neutral_midtone_coverage_pct": share(neutral_count), "r_over_g": rog, "b_over_g": bog, "cast_hint": cast},
            "saturation": {"mean_s_pct": round((sat_sum / total) * 100.0, 2), "p95_s_pct": round(pct(sats, 0.95) * 100.0, 2),
                           "low_sat_pct": share(low_sat), "melting_saturation_pct": share(melting_sat),
                           "melting_warning": share(melting_sat) > 2.0},
            "hsl_channels": hsl_out, "samples": samples_out,
        }


def _write_png_rgb8(path: pathlib.Path, width: int, height: int, rows_bytes: list[bytes]) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    raw = b"".join(b"\x00" + r for r in rows_bytes)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class BshCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rawlab-bsh-cli-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def run_cli(self, *args):
        return subprocess.run(
            [str(CLI), *map(str, args)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=120,
        )

    def assert_parity(self, cli_diag: dict, ref_diag: dict) -> None:
        self.assertEqual(cli_diag["dimensions"]["width"], ref_diag["dimensions"]["width"])
        self.assertEqual(cli_diag["dimensions"]["height"], ref_diag["dimensions"]["height"])
        self.assertEqual(cli_diag["dimensions"]["sampled_pixels"], ref_diag["dimensions"]["sampled_pixels"])
        self.assertEqual(cli_diag["color_balance"]["cast_hint"], ref_diag["color_balance"]["cast_hint"])
        self.assertEqual(cli_diag["saturation"]["melting_warning"], ref_diag["saturation"]["melting_warning"])

        for key in ("blacks_0_10_pct", "shadows_10_35_pct", "midtones_35_65_pct", "lights_65_90_pct", "highlights_90_100_pct"):
            self.assertLessEqual(abs(cli_diag["luma_zones"][key] - ref_diag["luma_zones"][key]), 0.2, key)
        self.assertLessEqual(abs(cli_diag["luma_zones"]["mean_luma_0_1"] - ref_diag["luma_zones"]["mean_luma_0_1"]), 0.002)
        for pkey in ("p01", "p05", "p25", "p50", "p75", "p95", "p99"):
            self.assertLessEqual(abs(cli_diag["luma_zones"]["percentiles_0_1"][pkey] - ref_diag["luma_zones"]["percentiles_0_1"][pkey]), 0.002, pkey)
        for key in ("shadow_crush_pct", "white_blowout_pct"):
            self.assertLessEqual(abs(cli_diag["clipping"][key] - ref_diag["clipping"][key]), 0.2, key)
        for key in ("any", "r", "g", "b"):
            self.assertLessEqual(abs(cli_diag["clipping"]["channel_clip_high_pct"][key] - ref_diag["clipping"]["channel_clip_high_pct"][key]), 0.2, key)
        self.assertLessEqual(abs(cli_diag["color_balance"]["r_over_g"] - ref_diag["color_balance"]["r_over_g"]), 0.002)
        self.assertLessEqual(abs(cli_diag["color_balance"]["b_over_g"] - ref_diag["color_balance"]["b_over_g"]), 0.002)
        for key in ("mean_s_pct", "p95_s_pct", "low_sat_pct", "melting_saturation_pct"):
            self.assertLessEqual(abs(cli_diag["saturation"][key] - ref_diag["saturation"][key]), 0.2, key)
        self.assertEqual(set(cli_diag["hsl_channels"].keys()), set(ref_diag["hsl_channels"].keys()))
        for cname, cval in ref_diag["hsl_channels"].items():
            got = cli_diag["hsl_channels"][cname]
            self.assertLessEqual(abs(got["coverage_pct"] - cval["coverage_pct"]), 0.2)
            self.assertLessEqual(abs(got["mean_sat_pct"] - cval["mean_sat_pct"]), 0.2)
            self.assertLessEqual(abs(got["mean_brightness_pct"] - cval["mean_brightness_pct"]), 0.2)

    def test_analyze_raw_recipe_no_file_written_and_parity_with_preview(self):
        dng = FIXTURES / "bayer-demosaic.dng"
        self.assertTrue(dng.is_file(), f"Missing fixture {dng}")
        unused_out = self.root / "should-not-exist.jpg"
        preview_png = self.root / "preview.png"
        recipe = self.root / "recipe.json"
        recipe.write_text(json.dumps({
            "schema_version": 17,
            "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
            "input": {"path": str(dng), "type": "raw"},
            "edits": {
                "exposure": {"mode": "preview", "ev": 0.25, "brightness": 1.0},
                "white_balance": {"mode": "camera"},
                "look": {"path": None, "strength": 1.0},
                "tone": {
                    "contrast": 1.1, "saturation": 1.05, "highlights": 0.0, "shadows": 0.1,
                    "s_curve": 0.0, "black_point": -0.05, "white_point": 0.05,
                    "curve": {
                        "mode": "legacy", "points": [],
                        "apply_to_luminosity": True,
                        "parametric": {
                            "highlights": -10, "lights": 5, "darks": 0, "shadows": 10,
                            "split_shadow": 0.25, "split_midtone": 0.5, "split_highlight": 0.75,
                        },
                    },
                },
                "color": {"vibrance": 0.12},
                "color_grading": {
                    "shadows": {"hue": 210, "saturation": 15, "luminance": -5},
                    "midtones": {"hue": 30, "saturation": 10, "luminance": 0},
                    "highlights": {"hue": 45, "saturation": 12, "luminance": 5},
                    "global": {"hue": 0, "saturation": 0, "luminance": 0},
                    "blending": 60, "balance": 10,
                },
                "detail": {"sharpening": 0.2},
                "hsl": {"hue": [0]*8, "saturation": [0]*8, "lightness": [0]*8},
                "effects": {"vignette_amount": 0, "vignette_midpoint": 50, "vignette_roundness": 0,
                            "vignette_feather": 50, "vignette_highlights": 0,
                            "grain_amount": 0, "grain_size": 25, "grain_roughness": 50,
                            "clarity": 0.1, "dehaze": 0.05},
                "denoise": {"raw_level": 0, "chroma_mode": 0,
                            "wavelet": {"enabled": False, "luma": 0, "chroma": 46, "coarse": 50}},
                "lens_correction": {"distortion": False, "tca": False, "vignetting": False, "auto_crop": True, "profile_id": None},
                "geometry": {"crop": {"x": 0, "y": 0, "width": 1, "height": 1}, "quarter_turns": 0,
                             "flip_horizontal": False, "flip_vertical": False, "straighten_degrees": 0,
                             "perspective": {"horizontal": 0, "vertical": 0}},
            },
            "output": {"path": str(unused_out), "format": "jpeg", "jpeg_quality": 95,
                       "size": {"mode": "limit_long_edge", "long_edge": 256}, "output_sharpening": "low"},
        }), encoding="utf-8")

        # 1. --analyze alone must NOT write output.path
        proc = self.run_cli("--recipe", recipe, "--analyze", "--sample", "0.5,0.5,center", "--sample", "0.2,0.2,skin", "--long-edge", "64", "--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(unused_out.exists())
        env = json.loads(proc.stdout)
        self.assertTrue(env["ok"])
        self.assertEqual(env["command"], "analyze")
        diag = env["result"]
        self.assertEqual(len(diag["samples"]), 2)
        self.assertNotIn("portrait_skin_check", diag["samples"][0])
        self.assertNotIn("portrait_skin_check", diag["samples"][1])
        self.assertNotIn("auto_diagnostics", diag)

        # 2. Combined --preview + --analyze writes PNG and matches Python reference within <0.2%
        proc2 = self.run_cli("--recipe", recipe, "--preview", preview_png, "--analyze", "--sample", "0.5,0.5,center", "--long-edge", "64", "--json")
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        self.assertTrue(preview_png.is_file())
        env2 = json.loads(proc2.stdout)
        self.assertEqual(env2["command"], "preview")
        ref = _ref_analyze_png(preview_png, [_ref_parse_sample_arg("0.5,0.5,center")])
        self.assert_parity(env2["result"]["diagnostics"], ref)
        self.assertEqual(env2["result"]["diagnostics"]["samples"][0]["rgb_8bit"], ref["samples"][0]["rgb_8bit"])

        # 3. --print-transfer produces valid AdjustmentTransferPayload v1 with expected scaling
        pt = self.run_cli("--recipe", recipe, "--print-transfer", "--json")
        self.assertEqual(pt.returncode, 0, pt.stderr)
        pt_env = json.loads(pt.stdout)
        self.assertEqual(pt_env["command"], "print_transfer")
        payload = pt_env["result"]
        self.assertEqual(payload["payload_version"], 1)
        self.assertEqual(payload["scope_version"], 1)
        self.assertTrue(payload["source"]["is_raw"])
        vals = payload["values"]
        self.assertAlmostEqual(vals["tone.black_point"], -5.0, places=3)
        self.assertAlmostEqual(vals["tone.white_point"], 5.0, places=3)
        self.assertAlmostEqual(vals["color.vibrance"], 12.0, places=3)
        self.assertAlmostEqual(vals["effects.clarity"], 10.0, places=3)
        self.assertAlmostEqual(vals["effects.dehaze"], 5.0, places=3)
        self.assertEqual(vals["light.curve.apply_to_luminosity"], True)
        self.assertEqual(vals["color.grading.blending"], 60.0)

    def test_analyze_input_direct_and_error_cases(self):
        if sys.platform in ("darwin", "win32"):
            png = self.root / "synthetic_skin.png"
            rows = []
            for y in range(32):
                row = bytearray()
                for x in range(32):
                    if x < 16:
                        row.extend((215, 165, 140)) # East Asian skin tone area
                    else:
                        row.extend((120, 125, 122)) # Neutral area
                rows.append(bytes(row))
            _write_png_rgb8(png, 32, 32, rows)

            proc = self.run_cli("--input", png, "--analyze", "--sample", "0.25,0.5,face", "--json")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            env = json.loads(proc.stdout)
            self.assertTrue(env["ok"])
            self.assertEqual(env["command"], "analyze")
            ref = _ref_analyze_png(png, [_ref_parse_sample_arg("0.25,0.5,face")])
            self.assert_parity(env["result"], ref)
            self.assertNotIn("portrait_skin_check", env["result"]["samples"][0])
            self.assertNotIn("auto_diagnostics", env["result"])

        # --sample without --analyze fails cleanly
        bad1 = self.run_cli("--recipe", self.root / "missing.json", "--sample", "0.5,0.5", "--json")
        self.assertNotEqual(bad1.returncode, 0)
        self.assertEqual(json.loads(bad1.stdout)["error"]["code"], "invalid_argument")

        # Out-of-range --sample fails cleanly (including negative)
        bad2 = self.run_cli("--input", self.root / "missing.png", "--analyze", "--sample", "-0.1,0.5", "--json")
        self.assertNotEqual(bad2.returncode, 0)
        self.assertEqual(json.loads(bad2.stdout)["error"]["code"], "invalid_argument")

        # Missing --input file returns io_error
        bad3 = self.run_cli("--input", self.root / "missing.png", "--analyze", "--json")
        self.assertNotEqual(bad3.returncode, 0)
        self.assertEqual(json.loads(bad3.stdout)["error"]["code"], "io_error")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    args, rest = parser.parse_known_args()
    CLI = args.cli.resolve()
    FIXTURES = args.fixtures.resolve()
    unittest.main(argv=[__file__, *rest])
