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
                for version in (1, 2):
                    identity = {"family": "rawlab", "version": version, "quality": "standard"}
                    document = {
                        "schema_version": 5, "processing": identity, "input": {"path": source.name},
                        "edits": {"exposure": {"mode": "scene", "ev": 0.25}},
                        "output": {"path": f"mcp-{version}.png", "format": "png"},
                    }
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    validated = await client.call_tool("validate_recipe", {"recipe_path": str(recipe)})
                    self.assertFalse(validated.is_error)
                    self.assertEqual(validated.structured_content["result"]["processing"], identity)
                    preview = root / f"mcp-preview-{version}.png"
                    rendered = await client.call_tool("render_preview", {
                        "recipe_path": str(recipe), "output_path": str(preview), "long_edge": 1280,
                    })
                    self.assertFalse(rendered.is_error)
                    direct_preview = root / f"cli-preview-{version}.png"
                    direct = subprocess.run([CLI, "--recipe", str(recipe), "--preview", str(direct_preview),
                                             "--long-edge", "1280", "--json"], capture_output=True, timeout=120)
                    self.assertEqual(direct.returncode, 0, direct.stderr)
                    self.assertEqual(preview.read_bytes(), direct_preview.read_bytes())
                    exported = await client.call_tool("export_photo", {"recipe_path": str(recipe)})
                    self.assertFalse(exported.is_error)
                    document["output"]["path"] = f"cli-{version}.png"
                    recipe.write_text(json.dumps(document), encoding="utf-8")
                    direct = subprocess.run([CLI, "--recipe", str(recipe), "--json"], capture_output=True, timeout=120)
                    self.assertEqual(direct.returncode, 0, direct.stderr)
                    self.assertEqual((root / f"mcp-{version}.png").read_bytes(), (root / f"cli-{version}.png").read_bytes())

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

                self.assertEqual(await call("capabilities"), direct("--capabilities"))
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
            (physical / "edit.json").write_text(json.dumps({
                "schema_version": 4,
                "input": {"path": source.name},
                "edits": {"exposure": {"mode": "scene", "ev": 0.0}},
                "output": {"path": "out.png", "format": "png"},
            }), encoding="utf-8")
            recipe = allowed / "alias" / ".." / "edit.json"

            direct = subprocess.run(
                [CLI, "--recipe", str(recipe), "--print-recipe", "--json"],
                capture_output=True, encoding="utf-8", check=False, timeout=120,
            )
            self.assertEqual(direct.returncode, 0, direct.stderr)
            direct_result = json.loads(direct.stdout)["result"]

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
            self.assertEqual(
                (direct_value["error"]["code"], direct_value["error"]["status"]),
                ("processing_error", 4),
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
