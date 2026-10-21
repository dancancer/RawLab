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
