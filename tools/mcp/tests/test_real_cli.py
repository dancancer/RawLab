"""Opt-in MCP/CLI parity checks using an explicit trusted CLI build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from mcp import Client, StdioServerParameters


CLI = os.environ.get("RAWLAB_MCP_CLI")
ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(CLI, "Set RAWLAB_MCP_CLI to run real CLI compatibility checks")
class RealCliTests(unittest.IsolatedAsyncioTestCase):
    async def test_v5_processing_versions_match_cli_pixels(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-v5-") as directory:
            root = Path(directory).resolve()
            source = root / "source.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            recipe = root / "recipe.json"
            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI, "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                for case, (version, extra) in enumerate(((1, {}), (2, {}), (2, {
                    "tone": {"black_point": .4, "white_point": -.3}, "color": {"vibrance": .6},
                }), (2, {
                    "color_grading": {"shadows": {"hue": 220, "saturation": 75},
                                      "midtones": {"hue": 110, "saturation": 0},
                                      "highlights": {"hue": 35.25, "saturation": 16.5}},
                    "tone": {"black_point": .25}, "color": {"vibrance": .5},
                }), (2, {
                    "tone": {"curve": {"mode": "custom", "points": [[0, 0], [.25, .12], [.75, .88], [1, 1]]},
                             "black_point": .25}, "color": {"vibrance": .5},
                }), (2, {
                    "effects": {"clarity": .65, "dehaze": -.4},
                    "tone": {"curve": {"mode": "custom", "points": [[0, 0], [.4, .3], [1, 1]]}},
                    "color_grading": {"shadows": {"hue": 220, "saturation": 20}},
                }))):
                    identity = {"family": "rawlab", "version": version, "quality": "standard"}
                    document = {
                        "schema_version": 5, "processing": identity, "input": {"path": source.name},
                        "edits": {"exposure": {"mode": "scene", "ev": 0.25}, **extra},
                        "output": {"path": f"mcp-{case}.png", "format": "png"},
                    }
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    validated = await client.call_tool("validate_recipe", {"recipe_path": str(recipe)})
                    self.assertFalse(validated.is_error)
                    self.assertEqual(validated.structured_content["result"]["processing"], identity)
                    for group, values in extra.items():
                        for field, value in values.items():
                            actual = validated.structured_content["result"]["edits"][group][field]
                            if isinstance(value, dict):
                                self.assertEqual(actual, value)
                            else:
                                self.assertAlmostEqual(actual, value, places=6)
                    preview = root / f"mcp-preview-{case}.png"
                    rendered = await client.call_tool("render_preview", {
                        "recipe_path": str(recipe), "output_path": str(preview), "long_edge": 1280,
                    })
                    self.assertFalse(rendered.is_error)
                    direct_preview = root / f"cli-preview-{case}.png"
                    direct = subprocess.run([CLI, "--recipe", str(recipe), "--preview", str(direct_preview),
                                             "--long-edge", "1280", "--json"], capture_output=True, timeout=120)
                    self.assertEqual(direct.returncode, 0, direct.stderr)
                    self.assertEqual(preview.read_bytes(), direct_preview.read_bytes())
                    exported = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                    self.assertFalse(exported.is_error)
                    document["output"]["path"] = f"cli-{case}.png"
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    direct = subprocess.run([CLI, "--recipe", str(recipe), "--json"], capture_output=True, timeout=120)
                    self.assertEqual(direct.returncode, 0, direct.stderr)
                    self.assertEqual((root / f"mcp-{case}.png").read_bytes(), (root / f"cli-{case}.png").read_bytes())

    async def test_five_tools_match_direct_cli_and_preserve_source(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-") as directory:
            root = Path(directory).resolve()
            source = root / "photo 空格.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            original = source.read_bytes()
            recipe = root / "recipe.json"
            document = {
                "schema_version": 4, "input": {"path": source.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.25}},
                "output": {"path": "mcp-export.png", "format": "png"},
            }
            recipe.write_text(json.dumps(document), encoding="utf-8")

            def direct(*arguments):
                process = subprocess.run([CLI, *map(str, arguments), "--json"],
                                         capture_output=True, encoding="utf-8", timeout=120)
                self.assertEqual(process.returncode, 0, process.stderr)
                value = json.loads(process.stdout)
                self.assertTrue(value["ok"])
                return value["result"]

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI, "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                async def call(name, **arguments):
                    value = await client.call_tool(name, arguments)
                    self.assertFalse(value.is_error, str(value))
                    return value.structured_content["result"]

                capabilities = direct("--capabilities")
                capabilities["recipe_versions"] = [
                    version for version in capabilities["recipe_versions"]
                    if version in range(1, 21)
                ]
                capabilities["commands"] = [
                    command for command in capabilities["commands"]
                    if command in (
                        "capabilities", "validate_recipe", "info", "preview", "export",
                        "analyze", "print_transfer", "save_preset", "sync_photo_edit",
                    )
                ]
                self.assertEqual(await call("capabilities"), capabilities)
                self.assertEqual(await call("image_info", image_path=str(source)), direct("--info", source))
                self.assertEqual(await call("validate_recipe", recipe_path=str(recipe)),
                                 direct("--recipe", recipe, "--print-recipe"))
                preview = root / "mcp-preview.png"
                mcp_result = await call("render_preview", recipe_path=str(recipe), output_path=str(preview), long_edge=1280)
                direct_result = direct("--recipe", recipe, "--preview", root / "cli-preview.png", "--long-edge", 1280)
                self.assertEqual({k: v for k, v in mcp_result.items() if k != "output_path"},
                                 {k: v for k, v in direct_result.items() if k != "output_path"})
                self.assertEqual(preview.read_bytes(), (root / "cli-preview.png").read_bytes())
                await call("export_photo", recipe_path=str(recipe))
                document["output"]["path"] = "cli-export.png"
                recipe.write_text(json.dumps(document), encoding="utf-8")
                direct("--recipe", recipe)
                self.assertEqual((root / "mcp-export.png").read_bytes(), (root / "cli-export.png").read_bytes())
                for hdr_version in (v for v in (14, 15) if v in capabilities["recipe_versions"]):
                    camera_source = root / "camera.dng"
                    shutil.copyfile(ROOT / "lutools/tests/fixtures/bayer-demosaic.dng", camera_source)
                    document = {
                        "schema_version": hdr_version,
                        "processing": {"family": "rawlab_hdr", "version": 7 if hdr_version == 14 else 8, "quality": "standard"},
                        "input": {"path": camera_source.name, "type": "raw", "camera_development": {
                            "white_balance_mode": "temperature", "temperature": 5300, "tint": 12}},
                        "edits": {"exposure": {"ev": .25}, "white_balance": {"mode": "relative"}},
                        "output": {"path": f"mcp-hdr-sdr-{hdr_version}.png", "format": "png"},
                    }
                    if hdr_version == 15:
                        document["edits"]["tone"] = {"curve": {"mode": "legacy", "points": [],
                            "channels": {"red": {"mode": "custom", "points": [[0, 0], [.5, .7], [1, 1]]}}}}
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    self.assertEqual(await call("validate_recipe", recipe_path=str(recipe)),
                                     direct("--recipe", recipe, "--print-recipe"))
                    await call("render_preview", recipe_path=str(recipe), output_path=str(root / f"mcp-hdr-preview-{hdr_version}.png"))
                    direct("--recipe", recipe, "--preview", root / f"cli-hdr-preview-{hdr_version}.png")
                    self.assertEqual((root / f"mcp-hdr-preview-{hdr_version}.png").read_bytes(), (root / f"cli-hdr-preview-{hdr_version}.png").read_bytes())
                    await call("export_photo", recipe_path=str(recipe))
                    document["output"]["path"] = f"cli-hdr-sdr-{hdr_version}.png"
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    direct("--recipe", recipe)
                    self.assertEqual((root / f"mcp-hdr-sdr-{hdr_version}.png").read_bytes(), (root / f"cli-hdr-sdr-{hdr_version}.png").read_bytes())

                document["edits"]["unknown_future_edit"] = 1
                document["output"]["path"] = "must-not-exist.png"
                recipe.write_text(json.dumps(document), encoding="utf-8")
                failure = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                self.assertTrue(failure.is_error)
                self.assertEqual(failure.structured_content["error"]["code"], "invalid_recipe")
                self.assertFalse((root / "must-not-exist.png").exists())
                recipe.write_text('{"schema_version": 4, "schema_version": 4}', encoding="utf-8")
                failure = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                self.assertTrue(failure.is_error)
                self.assertEqual(failure.structured_content["error"]["code"], "invalid_recipe")
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(list(root.glob(".rawlab-mcp-*")), [])

    async def test_symlink_input_and_output_parent_preserve_cli_fields_and_pixels(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-symlink-") as directory:
            root = Path(directory).resolve()
            source = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            input_link = root / "photo-link.dng"
            input_link.symlink_to(source)
            physical = root / "physical"
            physical.mkdir()
            output_alias = root / "output-alias"
            output_alias.symlink_to(physical, target_is_directory=True)

            direct_info = subprocess.run(
                [CLI, "--info", str(input_link), "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct_info.returncode, 0, direct_info.stderr)
            direct_info_result = json.loads(direct_info.stdout)["result"]

            direct_recipe = root / "direct.json"
            direct_recipe.write_text(json.dumps({
                "schema_version": 4,
                "input": {"path": input_link.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.0}},
                "output": {"path": str(output_alias / "direct.png"), "format": "png"},
            }), encoding="utf-8")
            direct_export = subprocess.run(
                [CLI, "--recipe", str(direct_recipe), "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct_export.returncode, 0, direct_export.stderr)
            direct_export_value = json.loads(direct_export.stdout)
            self.assertTrue(direct_export_value["ok"])

            mcp_recipe = root / "mcp.json"
            mcp_recipe.write_text(json.dumps({
                "schema_version": 4,
                "input": {"path": input_link.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.0}},
                "output": {"path": str(output_alias / "mcp.png"), "format": "png"},
            }), encoding="utf-8")
            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                info = await client.call_tool("image_info", {"image_path": str(input_link)})
                self.assertFalse(info.is_error, str(info))
                self.assertEqual(info.structured_content["result"], direct_info_result)
                exported = await client.call_tool("export_photo", {"recipe_path": str(mcp_recipe)})
                self.assertFalse(exported.is_error, str(exported))
                self.assertEqual(
                    exported.structured_content["result"]["format"],
                    direct_export_value["result"]["format"],
                )
                self.assertEqual(
                    exported.structured_content["result"]["output_path"],
                    str(output_alias / "mcp.png"),
                )
            self.assertEqual((physical / "mcp.png").read_bytes(), (physical / "direct.png").read_bytes())
            self.assertEqual(list(root.glob(".rawlab-mcp-*")), [])

    async def test_recipe_source_keeps_raw_lexical_path_for_native_open(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-recipe-path-") as directory:
            root = Path(directory).resolve()
            allowed = root / "allowed"
            physical = allowed / "physical"
            nested = physical / "nested"
            allowed.mkdir()
            nested.mkdir(parents=True)
            alias = allowed / "alias"
            alias.symlink_to(nested, target_is_directory=True)
            source = allowed / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            document = {
                "schema_version": 4,
                "input": {"path": source.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.0}},
                "output": {"path": "out.png", "format": "png"},
            }
            (physical / "edit.json").write_text(json.dumps(document), encoding="utf-8")
            # Win32 在打开文件前归一化 ..；POSIX 先跟随目录软链接。
            document["edits"]["exposure"]["ev"] = 0.5
            (allowed / "edit.json").write_text(json.dumps(document), encoding="utf-8")
            recipe = allowed / "alias" / ".." / "edit.json"

            direct = subprocess.run(
                [CLI, "--recipe", str(recipe), "--print-recipe", "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct.returncode, 0, direct.stderr)
            direct_result = json.loads(direct.stdout)["result"]
            self.assertEqual(direct_result["edits"]["exposure"]["ev"], 0.5 if os.name == "nt" else 0.0)

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(allowed), "--write-root", str(allowed),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                result = await client.call_tool("validate_recipe", {"recipe_path": str(recipe)})
                self.assertFalse(result.is_error, str(result))
                self.assertEqual(result.structured_content["result"], direct_result)

    async def test_missing_look_preserves_native_cli_error(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-missing-look-") as directory:
            root = Path(directory).resolve()
            source = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            recipe = root / "recipe.json"
            recipe.write_text(json.dumps({
                "schema_version": 4,
                "input": {"path": source.name},
                "edits": {
                    "exposure": {"mode": "scene", "ev": 0.0},
                    "look": {"path": "missing.cube"},
                },
                "output": {"path": "mcp.png", "format": "png"},
            }), encoding="utf-8")

            direct = subprocess.run(
                [CLI, "--recipe", str(recipe), "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertNotEqual(direct.returncode, 0)
            direct_value = json.loads(direct.stdout)
            self.assertFalse(direct_value["ok"])
            self.assertEqual(
                (direct_value["error"]["code"], direct_value["error"]["status"]),
                ("unsupported", 2),
            )

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                result = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                self.assertTrue(result.is_error, str(result))
                self.assertEqual(
                    (result.structured_content["error"]["code"], result.structured_content["error"]["status"]),
                    ("unsupported", 2),
                )
            self.assertFalse((root / "mcp.png").exists())
            self.assertEqual(list(root.glob(".rawlab-mcp-*")), [])

    async def test_missing_output_parent_is_mcp_policy_not_native_parity(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-missing-parent-") as directory:
            root = Path(directory).resolve()
            source = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            recipe = root / "recipe.json"
            recipe.write_text(json.dumps({
                "schema_version": 4,
                "input": {"path": source.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.0}},
                "output": {"path": "missing/mcp.png", "format": "png"},
            }), encoding="utf-8")

            direct = subprocess.run(
                [CLI, "--recipe", str(recipe), "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertNotEqual(direct.returncode, 0)
            direct_value = json.loads(direct.stdout)
            self.assertFalse(direct_value["ok"])
            # Contract: lutools/docs/edit-json.md ("JPEG, PNG and DNG encoding all
            # publish through staged writes, so an output storage failure reports
            # status 6 (output_io_error) for every format"). 2aa25048 (PR #242)
            # migrated PNG to staged writes; 3ad54e63 realigned the CLI assertions
            # and a6ffa929 synced the spec. A missing output parent is such a
            # storage failure, so the native side reports output_io_error(6).
            self.assertEqual(
                (direct_value["error"]["code"], direct_value["error"]["status"]),
                ("output_io_error", 6),
            )

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                result = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                self.assertTrue(result.is_error, str(result))
                self.assertEqual(
                    (result.structured_content["error"]["code"], result.structured_content["error"]["status"]),
                    ("invalid_argument", None),
                )
            self.assertFalse((root / "missing" / "mcp.png").exists())
            self.assertEqual(list(root.glob(".rawlab-mcp-*")), [])

    async def test_diagnose_image_matches_cli_and_schema(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-real-analyze-") as directory:
            root = Path(directory).resolve()
            source = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            recipe = root / "recipe.json"
            recipe.write_text(json.dumps({
                "schema_version": 5,
                "processing": {"family": "rawlab", "version": 2, "quality": "standard"},
                "input": {"path": source.name},
                "edits": {
                    "exposure": {"mode": "scene", "ev": 0.35},
                    "tone": {"saturation": 1.15},
                    "color": {"vibrance": 0.25},
                },
                "output": {"path": "unused.png", "format": "png"},
            }), encoding="utf-8")

            direct_img = subprocess.run(
                [CLI, "--input", str(source), "--analyze", "--sample", "0.5,0.5,center", "--long-edge", "1024", "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct_img.returncode, 0, direct_img.stderr)
            direct_img_json = json.loads(direct_img.stdout)
            self.assertTrue(direct_img_json["ok"])
            self.assertNotIn("auto_diagnostics", direct_img_json["result"])
            self.assertNotIn("portrait_skin_check", direct_img_json["result"]["samples"][0])

            direct_recipe = subprocess.run(
                [CLI, "--recipe", str(recipe), "--analyze", "--sample", "0.5,0.5,skin", "--long-edge", "512", "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct_recipe.returncode, 0, direct_recipe.stderr)
            direct_recipe_json = json.loads(direct_recipe.stdout)
            self.assertTrue(direct_recipe_json["ok"])
            self.assertNotIn("auto_diagnostics", direct_recipe_json["result"])
            self.assertNotIn("portrait_skin_check", direct_recipe_json["result"]["samples"][0])

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                caps = await client.call_tool("capabilities")
                self.assertIn("analyze", caps.structured_content["result"]["commands"])
                self.assertIn(17, caps.structured_content["result"]["recipe_versions"])

                mcp_img = await client.call_tool("diagnose_image", {
                    "image_path": str(source),
                    "samples": ["0.5,0.5,center"],
                    "long_edge": 1024,
                })
                self.assertFalse(mcp_img.is_error, str(mcp_img))
                img_diag = mcp_img.structured_content["result"]
                self.assertIsInstance(img_diag.get("auto_diagnostics"), list)
                for key, val in direct_img_json["result"].items():
                    self.assertEqual(img_diag[key], val)

                mcp_recipe = await client.call_tool("diagnose_image", {
                    "recipe_path": str(recipe),
                    "samples": ["0.5,0.5,skin"],
                    "long_edge": 512,
                })
                self.assertFalse(mcp_recipe.is_error, str(mcp_recipe))
                diag = mcp_recipe.structured_content["result"]
                self.assertIsInstance(diag.get("auto_diagnostics"), list)
                for key, val in direct_recipe_json["result"].items():
                    if key != "samples":
                        self.assertEqual(diag[key], val)
                self.assertEqual(len(diag["samples"]), 1)
                for key, val in direct_recipe_json["result"]["samples"][0].items():
                    self.assertEqual(diag["samples"][0][key], val)
                self.assertIn("luma_zones", diag)
                self.assertIn("color_balance", diag)
                self.assertIn("saturation", diag)
                self.assertIn("hsl_channels", diag)
                self.assertIn("portrait_skin_check", diag["samples"][0])

    async def test_print_transfer_roundtrips_into_save_preset(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-print-transfer-") as directory:
            root = Path(directory).resolve()
            source = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", source)
            recipe = root / "recipe_v17.json"
            recipe.write_text(json.dumps({
                "schema_version": 17,
                "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
                "input": {"path": source.name, "type": "raw"},
                "edits": {
                    "exposure": {"mode": "preview", "ev": 0.45, "brightness": 1.0},
                    "white_balance": {"mode": "camera"},
                    "look": {"path": None, "strength": 1.0},
                    "tone": {
                        "contrast": 1.15,
                        "saturation": 1.1,
                        "highlights": 0.0,
                        "shadows": 0.1,
                        "s_curve": 0.0,
                        "black_point": -0.05,
                        "white_point": 0.05,
                        "curve": {
                            "mode": "custom",
                            "points": [[0.0, 0.0], [0.5, 0.56], [1.0, 1.0]],
                            "channels": {"red": {"mode": "custom", "points": [[0.0, 0.0], [1.0, 1.0]]}},
                            "apply_to_luminosity": True,
                            "parametric": {
                                "highlights": -10, "lights": 6, "darks": -4, "shadows": 12,
                                "split_shadow": 0.25, "split_midtone": 0.5, "split_highlight": 0.75,
                            },
                        },
                    },
                    "color": {"vibrance": 0.12},
                    "color_grading": {
                        "shadows": {"hue": 220, "saturation": 25, "luminance": -6},
                        "midtones": {"hue": 0, "saturation": 0, "luminance": 0},
                        "highlights": {"hue": 0, "saturation": 0, "luminance": 0},
                        "global": {"hue": 180, "saturation": 10, "luminance": 2},
                        "blending": 62,
                        "balance": -8,
                    },
                },
                "output": {"path": "unused.png", "format": "png"},
            }), encoding="utf-8")

            transfer = subprocess.run(
                [CLI, "--recipe", str(recipe), "--print-transfer", "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(transfer.returncode, 0, f"stdout={transfer.stdout} stderr={transfer.stderr}")
            transfer_doc = json.loads(transfer.stdout)
            self.assertTrue(transfer_doc["ok"])
            payload = transfer_doc["result"]

            data_dir = root / "appdata"
            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
                "--enable-gui-sync", "--data-dir", str(data_dir),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                saved = await client.call_tool("save_preset", {
                    "name": "CLI Transfer V17",
                    "values": payload["values"],
                    "is_raw": payload["source"]["is_raw"],
                    "processing_version": payload["source"]["processing_version"],
                })
                self.assertFalse(saved.is_error, str(saved))
                self.assertTrue((data_dir / "Presets" / "presets.json").is_file())

    async def test_gui_sync_end_to_end_presets_and_photo_edits(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-gui-e2e-") as directory:
            root = Path(directory).resolve()
            data_dir = root / "appdata"
            raw_photo = root / "photo.dng"
            sibling_photo = root / "sibling.jpg"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", raw_photo)
            sibling_photo.write_bytes(b"sibling-jpg")

            # Seed unreadable future preset + retired_ids to verify verbatim preservation
            presets_dir = data_dir / "Presets"
            presets_dir.mkdir(parents=True)
            raw_unreadable = (
                '{  "name" : "Future V99",  "id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", '
                '"created_at": 1, "updated_at": 1, '
                '"payload": { "payload_version": 99, "ratio": 1.000, "extra": [ 1, 2 ] }  }'
            )
            (presets_dir / "presets.json").write_text(
                '{"registry_version":1,"presets":[' + raw_unreadable + '],"retired_ids":["11111111-2222-4333-8444-555555555555"]}',
                encoding="utf-8",
            )

            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "rawlab_mcp", "--cli", CLI,
                "--read-root", str(root), "--write-root", str(root),
                "--enable-gui-sync", "--data-dir", str(data_dir),
            ], env={**os.environ, "PYTHONPATH": str(ROOT / "tools/mcp/src")})
            async with Client(params) as client:
                # 1. save_preset creates, rejects duplicate without overwrite, then updates
                created = await client.call_tool("save_preset", {
                    "name": "  Real  Look\u00a0",
                    "values": {"light.exposure": 0.4, "light.curve.apply_to_luminosity": True},
                })
                self.assertFalse(created.is_error, str(created))
                self.assertEqual(created.structured_content["result"]["action"], "created")
                self.assertEqual(created.structured_content["result"]["name"], "Real  Look")

                dup = await client.call_tool("save_preset", {
                    "name": "Real  Look",
                    "values": {"light.exposure": 0.8},
                })
                self.assertTrue(dup.is_error)
                self.assertEqual(dup.structured_content["error"]["code"], "invalid_argument")

                updated = await client.call_tool("save_preset", {
                    "name": "Real  Look",
                    "values": {"light.exposure": 0.8},
                    "overwrite": True,
                })
                self.assertFalse(updated.is_error, str(updated))
                self.assertEqual(updated.structured_content["result"]["action"], "updated")

                raw_presets_text = (presets_dir / "presets.json").read_text(encoding="utf-8")
                self.assertIn(raw_unreadable, raw_presets_text)
                presets_doc = json.loads(raw_presets_text)
                self.assertEqual(presets_doc["retired_ids"], ["11111111-2222-4333-8444-555555555555"])

                # 2. HDR v1..v9 validation
                bad_hdr = await client.call_tool("save_preset", {
                    "name": "Bad HDR v1",
                    "hdr_processing_version": 1,
                    "is_raw": False,
                    "values": {"light.curve": {"mode": "legacy", "points": []}},
                })
                self.assertTrue(bad_hdr.is_error)

                ok_hdr9 = await client.call_tool("save_preset", {
                    "name": "Good HDR v9",
                    "hdr_processing_version": 9,
                    "is_raw": False,
                    "values": {
                        "light.exposure": 0.3,
                        "light.curve.apply_to_luminosity": True,
                        "color.grading.global": {"hue": 40, "saturation": 20, "luminance": -5},
                    },
                })
                self.assertFalse(ok_hdr9.is_error, str(ok_hdr9))

                # 3. sync_photo_edit end-to-end on desktop OS (or unsupported=4 on Linux)
                sync_first = await client.call_tool("sync_photo_edit", {
                    "photo_path": str(raw_photo),
                    "adjustments": {"exposure": 0.65, "processing_version": 2},
                    "film_id": "builtin:classic_chrome",
                })
                if sys.platform not in ("darwin", "win32"):
                    self.assertTrue(sync_first.is_error)
                    self.assertEqual(sync_first.structured_content["error"]["code"], "unsupported")
                    self.assertEqual(sync_first.structured_content["error"]["status"], 4)
                    return

                self.assertFalse(sync_first.is_error, str(sync_first))
                photo_key = sync_first.structured_content["result"]["photo_path"]
                edits_path = data_dir / "Edits" / "edits.json"
                edits_doc = json.loads(edits_path.read_text(encoding="utf-8"))

                # Inject unknown field, sibling raw slice, and migration receipt, then update processing_version -> 3
                sibling_slice = '{"customSibling":123.000,"identity":{"size":11}}'
                if sys.platform == "darwin":
                    edits_doc["records"][photo_key]["state"]["settings"]["customUntouched"] = "keep-me"
                    edits_doc["processingMigrations"] = {
                        photo_key: {"status": "kept"},
                        str(sibling_photo): {"status": "keep-sibling"},
                    }
                    edits_text = (
                        '{"records":{'
                        + json.dumps(photo_key) + ':' + json.dumps(edits_doc["records"][photo_key])
                        + ',' + json.dumps(str(sibling_photo)) + ':' + sibling_slice
                        + '},"processingMigrations":' + json.dumps(edits_doc["processingMigrations"])
                        + ',"version":1}'
                    )
                else:
                    edits_doc["Records"][photo_key]["Settings"]["CustomUntouched"] = "keep-me"
                    edits_doc["MigrationReceipts"] = {
                        photo_key: {"Status": "kept"},
                        str(sibling_photo): {"Status": "keep-sibling"},
                    }
                    edits_text = (
                        '{"Records":{'
                        + json.dumps(photo_key) + ':' + json.dumps(edits_doc["Records"][photo_key])
                        + ',' + json.dumps(str(sibling_photo)) + ':' + sibling_slice
                        + '},"MigrationReceipts":' + json.dumps(edits_doc["MigrationReceipts"])
                        + ',"Version":1}'
                    )
                edits_path.write_text(edits_text, encoding="utf-8")

                sync_second = await client.call_tool("sync_photo_edit", {
                    "photo_path": str(raw_photo),
                    "adjustments": {"exposure": 1.1, "processing_version": 3},
                })
                self.assertFalse(sync_second.is_error, str(sync_second))
                self.assertEqual(sync_second.structured_content["result"]["action"], "updated")

                final_edits_raw = edits_path.read_text(encoding="utf-8")
                self.assertIn(sibling_slice, final_edits_raw)
                final_edits = json.loads(final_edits_raw)
                if sys.platform == "darwin":
                    self.assertEqual(final_edits["records"][photo_key]["state"]["settings"]["customUntouched"], "keep-me")
                    self.assertEqual(final_edits["records"][photo_key]["state"]["settings"]["exposure"], 1.1)
                    self.assertNotIn(photo_key, final_edits.get("processingMigrations", {}))
                    self.assertIn(str(sibling_photo), final_edits["processingMigrations"])
                else:
                    self.assertEqual(final_edits["Records"][photo_key]["Settings"]["CustomUntouched"], "keep-me")
                    self.assertEqual(final_edits["Records"][photo_key]["Settings"]["Values"][1], 1.1)
                    self.assertNotIn(photo_key, final_edits.get("MigrationReceipts", {}))
                    self.assertIn(str(sibling_photo), final_edits["MigrationReceipts"])

    def test_gui_sync_synchronous_default_cli_runner(self):
        from unittest.mock import patch
        from rawlab_mcp import gui_sync
        from rawlab_mcp.errors import AdapterError

        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-gui-sync-default-") as directory:
            root = Path(directory).resolve()
            data_dir = root / "appdata"
            photo = root / "photo.dng"
            shutil.copyfile(ROOT / "lutools/tests/fixtures/linear-uncompressed.dng", photo)

            with patch.dict(os.environ, {"RAWLAB_MCP_CLI": str(Path(CLI).resolve())}):
                preset_res = gui_sync.save_preset(
                    data_dir=data_dir,
                    name="SyncDefaultRunner",
                    values={"light.exposure": 0.35},
                )
                self.assertEqual(preset_res["action"], "created")
                self.assertTrue((data_dir / "Presets" / "presets.json").is_file())

                if sys.platform in ("darwin", "win32"):
                    edit_res = gui_sync.sync_photo_edit(
                        data_dir=data_dir,
                        photo_canonical=photo,
                        adjustments={"exposure": 0.55},
                        is_raster=False,
                        film_id="builtin:classic_chrome",
                    )
                    self.assertEqual(edit_res["action"], "created")
                    self.assertEqual(edit_res["filmID"], "builtin:classic_chrome")
                    self.assertTrue((data_dir / "Edits" / "edits.json").is_file())
                else:
                    with self.assertRaises(AdapterError) as ctx:
                        gui_sync.sync_photo_edit(
                            data_dir=data_dir,
                            photo_canonical=photo,
                            adjustments={"exposure": 0.55},
                            is_raster=False,
                        )
                    self.assertEqual(ctx.exception.code, "unsupported")
                    self.assertEqual(ctx.exception.status, 4)
