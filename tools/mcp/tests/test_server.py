import asyncio
import os
from pathlib import Path
import sys
import unittest

from mcp import Client, StdioServerParameters

import test_adapter
from subprocess_support import process_exited


SERVER_MODULE = "mcp_test_server_runner" if os.name == "nt" else "rawlab_mcp"
TEST_PYTHONPATH = os.pathsep.join((str(test_adapter.SRC), str(Path(__file__).parent)))


class StdioTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.fixture = test_adapter.AdapterTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.temporary.cleanup)

    async def test_cancelled_call_stops_only_its_cli_and_keeps_server_available(self):
        f = self.fixture
        pid_log = f.root / "pid"
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", SERVER_MODULE, "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": TEST_PYTHONPATH, "FAKE_SLEEP": "5",
                 "RAWLAB_MCP_TEST_CLI_SCRIPT": str(f.cli),
                 "FAKE_PID_LOG": str(pid_log), "FAKE_ARGV_LOG": str(f.argv_log), "FAKE_RECIPE_LOG": str(f.recipe_log)},
        )
        async with Client(params) as client:
            task = asyncio.create_task(client.call_tool("export_photo", {"recipe_path": str(f.recipe_path)}))
            async with asyncio.timeout(3):
                while not pid_log.exists():
                    await asyncio.sleep(0.01)
            pid = int(pid_log.read_text())
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            async with asyncio.timeout(3):
                while list(f.write_root.glob(".rawlab-mcp-*")):
                    await asyncio.sleep(0.01)
            self.assertTrue(process_exited(pid), "Cancelled CLI process is still alive")
            self.assertFalse((f.write_root / "export.jpg").exists())
            result = await client.call_tool("image_info", {"image_path": str(f.input_path)})
            self.assertFalse(result.is_error)

    async def test_handshake_five_tools_and_structured_errors(self):
        f = self.fixture
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", SERVER_MODULE, "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": TEST_PYTHONPATH,
                 "RAWLAB_MCP_TEST_CLI_SCRIPT": str(f.cli),
                 "FAKE_ARGV_LOG": str(f.argv_log), "FAKE_RECIPE_LOG": str(f.recipe_log)},
        )
        async with Client(params) as client:
            tools = (await client.list_tools()).tools
            self.assertEqual({tool.name for tool in tools}, {
                "capabilities", "validate_recipe", "image_info", "render_preview", "export_photo",
                "diagnose_image", "list_catalog_looks",
            })
            # Write/sync tools MUST NOT be exposed or callable by default
            self.assertNotIn("save_preset", {tool.name for tool in tools})
            self.assertNotIn("sync_photo_edit", {tool.name for tool in tools})
            denied = await client.call_tool("save_preset", {"name": "Blocked", "values": {"light.exposure": 0.5}})
            self.assertTrue(denied.is_error)

            catalog_res = await client.call_tool("list_catalog_looks", {"category": "master_recipe"})
            self.assertFalse(catalog_res.is_error, str(catalog_res))
            self.assertEqual(catalog_res.structured_content["result"]["total_count"], 14)

            result = await client.call_tool("capabilities")
            self.assertFalse(result.is_error)
            self.assertEqual(result.structured_content["result"]["recipe_versions"], [1, 2, 3, 4])
            for name, arguments in [
                ("validate_recipe", {"recipe_path": str(f.recipe_path)}),
                ("image_info", {"image_path": str(f.input_path)}),
                ("render_preview", {"recipe_path": str(f.recipe_path), "output_path": str(f.write_root / "preview.png")}),
                ("export_photo", {"recipe_path": str(f.recipe_path)}),
            ]:
                result = await client.call_tool(name, arguments)
                self.assertFalse(result.is_error, str(result))
                self.assertTrue(result.structured_content["ok"])
            result = await client.call_tool("export_photo", {"recipe_path": str(f.recipe_path)})
            self.assertTrue(result.is_error)
            self.assertEqual(result.structured_content["error"]["code"], "invalid_argument")
            result = await client.call_tool("render_preview", {
                "recipe_path": str(f.recipe_path), "output_path": str(f.write_root / "bad.png"), "long_edge": 0,
            })
            self.assertTrue(result.is_error)
            self.assertFalse((f.write_root / "bad.png").exists())
            result = await client.call_tool("image_info", {
                "image_path": str(f.input_path), "command": "rm",
            })
            self.assertTrue(result.is_error)

    async def test_illegal_paths_remain_structured_invalid_arguments(self):
        f = self.fixture
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", SERVER_MODULE, "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": TEST_PYTHONPATH,
                 "RAWLAB_MCP_TEST_CLI_SCRIPT": str(f.cli),
                 "FAKE_ARGV_LOG": str(f.argv_log), "FAKE_RECIPE_LOG": str(f.recipe_log)},
        )
        async with Client(params) as client:
            for name, arguments in [
                ("image_info", {"image_path": str(f.input_path) + "\x00tail"}),
                ("validate_recipe", {"recipe_path": str(f.recipe_path) + "\x00tail"}),
                ("render_preview", {"recipe_path": str(f.recipe_path),
                                     "output_path": str(f.write_root / "bad\x00.png")}),
            ]:
                result = await client.call_tool(name, arguments)
                self.assertTrue(result.is_error)
                self.assertEqual(result.structured_content["error"]["code"], "invalid_argument")
                self.assertIsNone(result.structured_content["error"]["status"])

    async def test_gui_sync_enabled_exposes_nine_tools_and_writes_inside_data_dir(self):
        f = self.fixture
        data_dir = f.root / "gui-sync-appdata"
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", SERVER_MODULE, "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root),
                  "--enable-gui-sync", "--data-dir", str(data_dir)],
            env={**os.environ, "PYTHONPATH": TEST_PYTHONPATH,
                 "RAWLAB_MCP_TEST_CLI_SCRIPT": str(f.cli),
                 "FAKE_ARGV_LOG": str(f.argv_log), "FAKE_RECIPE_LOG": str(f.recipe_log)},
        )
        async with Client(params) as client:
            tools = (await client.list_tools()).tools
            self.assertEqual({tool.name for tool in tools}, {
                "capabilities", "validate_recipe", "image_info", "render_preview", "export_photo",
                "diagnose_image", "list_catalog_looks", "save_preset", "sync_photo_edit",
            })
            extra_rejected = await client.call_tool("save_preset", {
                "name": "P", "values": {"light.exposure": 0.2}, "unexpected": True,
            })
            self.assertTrue(extra_rejected.is_error)
            self.assertEqual(extra_rejected.structured_content["error"]["code"], "invalid_argument")

            saved = await client.call_tool("save_preset", {
                "name": "Server Preset", "values": {"light.exposure": 0.25},
            })
            self.assertFalse(saved.is_error, str(saved))
            self.assertTrue((data_dir / "Presets" / "presets.json").is_file())

            saved_hdr = await client.call_tool("save_preset", {
                "name": "Server HDR v9",
                "hdr_processing_version": 9,
                "values": {
                    "hdr.relative_temperature": 6000.0,
                    "hdr.peak_limit_ev": 2.5,
                    "light.curve.parametric": {
                        "highlights": 5.0, "lights": 0.0, "darks": 0.0, "shadows": -5.0,
                        "split_shadow": 0.25, "split_midtone": 0.5, "split_highlight": 0.75,
                    },
                },
            })
            self.assertFalse(saved_hdr.is_error, str(saved_hdr))


if __name__ == "__main__":
    unittest.main()
