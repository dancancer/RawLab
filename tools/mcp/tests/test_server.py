import asyncio
import os
from pathlib import Path
import sys
import unittest

from mcp import Client, StdioServerParameters

import test_adapter


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
            args=["-m", "rawlab_mcp", "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": str(test_adapter.SRC), "FAKE_SLEEP": "5",
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
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            self.assertFalse((f.write_root / "export.jpg").exists())
            result = await client.call_tool("image_info", {"image_path": str(f.input_path)})
            self.assertFalse(result.is_error)

    async def test_handshake_five_tools_and_structured_errors(self):
        f = self.fixture
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", "rawlab_mcp", "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": str(test_adapter.SRC),
                 "FAKE_ARGV_LOG": str(f.argv_log), "FAKE_RECIPE_LOG": str(f.recipe_log)},
        )
        async with Client(params) as client:
            tools = (await client.list_tools()).tools
            self.assertEqual({tool.name for tool in tools}, {
                "capabilities", "validate_recipe", "image_info", "render_preview", "export_photo",
            })
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
            args=["-m", "rawlab_mcp", "--cli", str(f.cli),
                  "--read-root", str(f.read_root), "--write-root", str(f.write_root)],
            env={**os.environ, "PYTHONPATH": str(test_adapter.SRC),
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


if __name__ == "__main__":
    unittest.main()
