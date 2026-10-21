import asyncio
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch
from pathlib import Path


SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from rawlab_mcp.adapter import AdapterError, CliAdapter  # noqa: E402
from rawlab_mcp.config import ServerConfig  # noqa: E402


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rawlab-mcp-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.read_root = self.root / "read"
        self.write_root = self.root / "write"
        self.recipe_dir = self.read_root / "album with spaces"
        self.read_root.mkdir()
        self.write_root.mkdir()
        self.recipe_dir.mkdir()
        self.input_path = self.recipe_dir / "photo 🌅.dng"
        self.look_path = self.recipe_dir / "look.cube"
        self.input_path.write_bytes(b"raw fixture")
        self.look_path.write_bytes(b"look fixture")
        self.recipe_path = self.recipe_dir / "edit.json"
        self.recipe_path.write_text(json.dumps({
            "schema_version": 4,
            "input": {"path": self.input_path.name},
            "edits": {
                "exposure": {"mode": "scene"},
                "look": {"path": self.look_path.name},
            },
            "output": {
                "path": "../../write/export.jpg",
                "format": "jpeg",
            },
        }), encoding="utf-8")
        self.argv_log = self.root / "argv.json"
        self.recipe_log = self.root / "recipe.json"
        self.cli = self._make_fake_cli()
        self.config = ServerConfig(
            cli=self.cli,
            read_roots=(self.read_root,),
            write_roots=(self.write_root,),
            timeout=2.0,
        )

    def _make_fake_cli(self) -> Path:
        script = self.root / "fake-cli.py"
        script.write_text(textwrap.dedent('''\
            #!/usr/bin/env python3
            import json
            import os
            import pathlib
            import sys
            import time

            args = sys.argv[1:]
            pathlib.Path(os.environ["FAKE_ARGV_LOG"]).write_text(json.dumps(args), encoding="utf-8")

            def envelope(command, result=None, error=None):
                return {"protocol_version": int(os.environ.get("FAKE_PROTOCOL", "1")), "command": command,
                        "ok": error is None, "result": result, "error": error}

            def emit(value, code=0):
                print(json.dumps(value, ensure_ascii=False))
                raise SystemExit(code)

            if "--capabilities" in args:
                versions = [int(value) for value in os.environ.get("FAKE_VERSIONS", "1,2,3,4").split(",")]
                emit(envelope("capabilities", {
                    "recipe_versions": versions,
                    "commands": os.environ.get("FAKE_COMMANDS", "capabilities,validate_recipe,info,preview,export").split(","),
                    "input_types": ["raw"],
                    "output_formats": ["jpeg", "png", "dng"],
                }))

            if "--info" in args:
                path = pathlib.Path(os.path.normpath(args[args.index("--info") + 1]))
                emit(envelope("info", {"input_path": str(path), "identified_size": {"width": 2, "height": 2}}))

            mode = "" if "--print-recipe" in args else os.environ.get("FAKE_MODE", "")
            if mode == "invalid_json":
                print("bad json")
                raise SystemExit(0)
            if mode == "wrong_command":
                emit(envelope("info", {}))
            if mode == "unknown_protocol":
                value = envelope("export", {})
                value["protocol_version"] = 99
                emit(value)
            if mode == "extra_field":
                value = envelope("export", {})
                value["unexpected"] = True
                emit(value)
            if mode == "exit_mismatch":
                emit(envelope("export", {}), 2)
            if mode == "cli_error":
                emit(envelope("export", error={"code": "output_io_error", "message": "disk full", "status": 6}), 6)

            recipe = None
            if "--recipe" in args:
                recipe_path = pathlib.Path(args[args.index("--recipe") + 1])
                recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
                pathlib.Path(os.environ["FAKE_RECIPE_LOG"]).write_text(
                    json.dumps(recipe, ensure_ascii=False), encoding="utf-8")
                if "--print-recipe" in args:
                    time.sleep(float(os.environ.get("FAKE_VALIDATE_SLEEP", "0")))
                    emit(envelope("validate_recipe", recipe))

            if os.environ.get("FAKE_SLEEP"):
                if os.environ.get("FAKE_PID_LOG"):
                    pathlib.Path(os.environ["FAKE_PID_LOG"]).write_text(str(os.getpid()))
                time.sleep(float(os.environ["FAKE_SLEEP"]))

            output = pathlib.Path(recipe["output"]["path"])
            command = "export"
            if "--preview" in args:
                output = pathlib.Path(args[args.index("--preview") + 1])
                command = "preview"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(b"fake-pixels")
            result = {"output_path": str(pathlib.Path(os.path.normpath(output))), "format": recipe["output"]["format"]}
            if command == "preview":
                result.update({"width": 2, "height": 2, "long_edge": 1280, "quality": "exact"})
            emit(envelope(command, result))
        '''), encoding="utf-8")
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        return script

    def adapter(self, **env):
        merged = {
            "FAKE_ARGV_LOG": str(self.argv_log),
            "FAKE_RECIPE_LOG": str(self.recipe_log),
        }
        merged.update(env)
        return CliAdapter(self.config, environment=merged)

    async def test_capabilities_negotiate_v4_and_hide_future_cli_versions(self):
        adapter = self.adapter(FAKE_VERSIONS="1,2,3,4,5")
        capabilities = await adapter.start()
        self.assertEqual(capabilities.recipe_versions, (1, 2, 3, 4))
        self.assertNotIn(5, capabilities.result["recipe_versions"])
        self.assertEqual(capabilities.result["commands"], [
            "capabilities", "validate_recipe", "info", "preview", "export",
        ])

    async def test_capabilities_reject_cli_without_v4(self):
        adapter = self.adapter(FAKE_VERSIONS="1,2,3")
        with self.assertRaisesRegex(AdapterError, "schema version 4"):
            await adapter.start()

    async def test_capabilities_reject_unknown_protocol_and_missing_commands(self):
        for environment in ({"FAKE_PROTOCOL": "2"}, {"FAKE_COMMANDS": "capabilities,info"}):
            with self.subTest(environment=environment):
                with self.assertRaises(AdapterError):
                    await self.adapter(**environment).start()

    async def test_export_resolves_original_recipe_paths_and_publishes_without_overwrite(self):
        adapter = self.adapter()
        await adapter.start()
        envelope = await adapter.export_photo(self.recipe_path)
        target = self.write_root / "export.jpg"
        self.assertTrue(target.is_file())
        self.assertEqual(target.read_bytes(), b"fake-pixels")
        self.assertEqual(envelope.result["output_path"], str(target))
        staged_recipe = json.loads(self.recipe_log.read_text(encoding="utf-8"))
        self.assertEqual(staged_recipe["input"]["path"], str(self.input_path))
        self.assertEqual(staged_recipe["edits"]["look"]["path"], str(self.look_path))
        self.assertNotEqual(staged_recipe["output"]["path"], str(target))
        self.assertTrue(Path(staged_recipe["output"]["path"]).parent.name.startswith(".rawlab-mcp-"))
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_existing_output_is_protected(self):
        target = self.write_root / "export.jpg"
        target.write_bytes(b"keep me")
        adapter = self.adapter()
        await adapter.start()
        envelope = await adapter.export_photo(self.recipe_path)
        self.assertFalse(envelope.ok)
        self.assertEqual(envelope.error.code, "invalid_argument")
        self.assertEqual(target.read_bytes(), b"keep me")

    async def test_recipe_path_escape_is_rejected_before_cli(self):
        outside = self.root / "outside.dng"
        outside.write_bytes(b"outside")
        recipe = self.recipe_dir / "escape.json"
        recipe.write_text(json.dumps({
            "schema_version": 4,
            "input": {"path": "../../outside.dng"},
            "edits": {"exposure": {"mode": "scene"}},
            "output": {"path": "../../write/escape.jpg", "format": "jpeg"},
        }), encoding="utf-8")
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        envelope = await adapter.validate_recipe(recipe)
        self.assertFalse(envelope.ok)
        self.assertEqual(envelope.error.code, "invalid_argument")
        self.assertIn("--print-recipe", json.loads(self.argv_log.read_text()))

    async def test_timeout_cleans_own_process_and_does_not_publish(self):
        adapter = self.adapter(FAKE_SLEEP="1")
        await adapter.start()
        adapter.config = ServerConfig(
            cli=self.cli, read_roots=(self.read_root,), write_roots=(self.write_root,), timeout=0.1)
        envelope = await adapter.export_photo(self.recipe_path)
        self.assertFalse(envelope.ok)
        self.assertEqual(envelope.error.code, "processing_error")
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_timeout_covers_validation_and_render_together(self):
        adapter = self.adapter(FAKE_VALIDATE_SLEEP="0.2", FAKE_SLEEP="0.2")
        await adapter.start()
        adapter.config = ServerConfig(self.cli, (self.read_root,), (self.write_root,), timeout=0.3)
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "processing_error")
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_cancellation_cleans_own_process_and_does_not_publish(self):
        adapter = self.adapter(FAKE_SLEEP="1")
        await adapter.start()
        task = asyncio.create_task(adapter.export_photo(self.recipe_path))
        await asyncio.sleep(0.05)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_image_info_uses_explicit_cli_mapping(self):
        adapter = self.adapter()
        await adapter.start()
        envelope = await adapter.image_info(self.input_path)
        self.assertTrue(envelope.ok)
        self.assertEqual(envelope.command, "info")
        self.assertEqual(json.loads(self.argv_log.read_text(encoding="utf-8")), [
            "--info", str(self.input_path), "--json",
        ])

    async def test_illegal_tool_paths_return_stable_invalid_argument(self):
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        invalid_paths = (str(self.input_path) + "\x00tail", str(self.input_path) + "\ud800")
        for invalid_path in invalid_paths:
            with self.subTest(path=repr(invalid_path)):
                results = await asyncio.gather(
                    adapter.image_info(invalid_path),
                    adapter.validate_recipe(invalid_path),
                    adapter.render_preview(self.recipe_path, invalid_path),
                )
                for result in results:
                    self.assertFalse(result.ok)
                    self.assertEqual((result.error.code, result.error.status), ("invalid_argument", None))
        self.assertFalse(self.argv_log.exists())

        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document["input"]["path"] = "photo\x00.dng"
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("invalid_argument", None))

    async def test_protocol_errors_and_nonzero_exit_never_publish(self):
        for mode in ("invalid_json", "wrong_command", "unknown_protocol", "extra_field", "exit_mismatch", "cli_error"):
            with self.subTest(mode=mode):
                adapter = self.adapter(FAKE_MODE=mode)
                await adapter.start()
                result = await adapter.export_photo(self.recipe_path)
                self.assertFalse(result.ok)
                if mode == "cli_error":
                    self.assertEqual((result.error.code, result.error.status), ("output_io_error", 6))
                else:
                    self.assertEqual(result.error.code, "processing_error")
                self.assertFalse((self.write_root / "export.jpg").exists())
                self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_symlink_and_missing_inputs_are_rejected_before_cli(self):
        outside = self.root / "outside.dng"
        outside.write_bytes(b"outside")
        link = self.read_root / "escape.dng"
        link.symlink_to(outside)
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        result = await adapter.image_info(link)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("invalid_argument", None))
        result = await adapter.image_info(self.read_root / "missing.dng")
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("io_error", 3))
        result = await adapter.image_info(self.root / "outside-missing.dng")
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("invalid_argument", None))
        self.assertFalse(self.argv_log.exists())
        self.look_path.unlink()
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("io_error", 3))
        self.assertIn("--print-recipe", json.loads(self.argv_log.read_text()))

    async def test_missing_recipe_is_io_error_status_three_before_cli(self):
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        result = await adapter.export_photo(self.recipe_dir / "missing.json")
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("io_error", 3))
        self.assertFalse(self.argv_log.exists())

    async def test_missing_recipe_source_is_io_error_status_three(self):
        self.input_path.unlink()
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("io_error", 3))
        self.assertEqual(json.loads(self.argv_log.read_text())[0], "--recipe")

    async def test_missing_output_parent_is_io_error_status_three(self):
        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document["output"]["path"] = "../../write/missing/export.jpg"
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("io_error", 3))

    async def test_malformed_and_future_recipes_are_rejected_before_cli(self):
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        for value in ("{bad json", "null", "[]", '{"schema_version":5}', '{"schema_version":true}'):
            self.recipe_path.write_text(value, encoding="utf-8")
            self.assertFalse((await adapter.export_photo(self.recipe_path)).ok)
        self.assertIn("--print-recipe", json.loads(self.argv_log.read_text()))

    async def test_publish_failure_cleans_private_files(self):
        adapter = self.adapter()
        await adapter.start()
        with patch("rawlab_mcp.adapter.os.link", side_effect=PermissionError("permission denied")):
            result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "output_io_error")
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_cleanup_failure_preserves_success_and_logs_private_directory(self):
        adapter = self.adapter()
        await adapter.start()
        with patch("rawlab_mcp.adapter.shutil.rmtree", side_effect=OSError("cleanup denied")):
            with self.assertLogs("rawlab_mcp.adapter", level="WARNING") as logs:
                result = await adapter.export_photo(self.recipe_path)
        self.assertTrue(result.ok, str(result.error))
        self.assertEqual((self.write_root / "export.jpg").read_bytes(), b"fake-pixels")
        self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
        self.assertIn("cleanup denied", "\n".join(logs.output))
        self.assertIn(".rawlab-mcp-", "\n".join(logs.output))
        self.temporary.cleanup()
        self.assertFalse(self.root.exists())

    async def test_cleanup_failure_preserves_cli_error(self):
        adapter = self.adapter(FAKE_MODE="cli_error")
        await adapter.start()
        with patch("rawlab_mcp.adapter.shutil.rmtree", side_effect=OSError("cleanup denied")):
            result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("output_io_error", 6))
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
        self.temporary.cleanup()
        self.assertFalse(self.root.exists())

    async def test_cleanup_failure_preserves_timeout(self):
        adapter = self.adapter(FAKE_SLEEP="1")
        await adapter.start()
        adapter.config = ServerConfig(self.cli, (self.read_root,), (self.write_root,), timeout=0.1)
        with patch("rawlab_mcp.adapter.shutil.rmtree", side_effect=OSError("cleanup denied")):
            result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "processing_error")
        self.assertIn("timed out", result.error.message)
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
        self.temporary.cleanup()
        self.assertFalse(self.root.exists())

    async def test_cleanup_failure_preserves_cancellation(self):
        adapter = self.adapter(FAKE_SLEEP="1")
        await adapter.start()
        task = asyncio.create_task(adapter.export_photo(self.recipe_path))
        await asyncio.sleep(0.05)
        with patch("rawlab_mcp.adapter.shutil.rmtree", side_effect=OSError("cleanup denied")):
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
        self.temporary.cleanup()
        self.assertFalse(self.root.exists())

    async def test_concurrent_requests_cannot_overwrite_same_output(self):
        adapter = self.adapter(FAKE_SLEEP="0.1")
        await adapter.start()
        results = await asyncio.gather(adapter.export_photo(self.recipe_path), adapter.export_photo(self.recipe_path))
        self.assertEqual(sum(result.ok for result in results), 1)
        self.assertEqual((self.write_root / "export.jpg").read_bytes(), b"fake-pixels")
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_close_during_spawn_reaps_process(self):
        adapter = self.adapter(FAKE_SLEEP="0.1")
        await adapter.start()
        task = asyncio.create_task(adapter.export_photo(self.recipe_path))
        await asyncio.sleep(0)
        await adapter.close()
        result = await task
        self.assertFalse(result.ok)
        self.assertFalse((self.write_root / "export.jpg").exists())

    async def test_dangling_output_symlink_is_rejected(self):
        target = self.write_root / "export.jpg"
        other = self.write_root / "other.jpg"
        target.symlink_to(other)
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertFalse(other.exists())

    async def test_validate_preserves_paths_without_opening_referenced_files(self):
        self.input_path.unlink()
        self.look_path.unlink()
        document = json.loads(self.recipe_path.read_text())
        document["output"]["path"] = "../../write/not-created/export.jpg"
        self.recipe_path.write_text(json.dumps(document))
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.validate_recipe(self.recipe_path)
        self.assertTrue(result.ok, str(result.error))
        self.assertEqual(result.result, document)
        self.assertFalse((self.write_root / "not-created").exists())

    async def test_symlink_recipe_preserves_lexical_relative_directory(self):
        alias = self.read_root / "alias"
        alias.mkdir()
        (alias / "edit.json").symlink_to(self.recipe_path)
        (alias / self.input_path.name).write_bytes(b"alias input")
        (alias / self.look_path.name).write_bytes(b"alias look")
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(alias / "edit.json")
        self.assertTrue(result.ok, str(result.error))
        rendered = json.loads(self.recipe_log.read_text())
        self.assertEqual(rendered["input"]["path"], str(alias / self.input_path.name))

    async def test_input_symlink_keeps_lexical_path_for_cli_and_result(self):
        link = self.recipe_dir / "photo-link.dng"
        link.symlink_to(self.input_path)
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.image_info(link)
        self.assertTrue(result.ok, str(result.error))
        self.assertEqual(result.result["input_path"], str(link))
        self.assertEqual(json.loads(self.argv_log.read_text(encoding="utf-8"))[1], str(link))

    async def test_output_parent_symlink_keeps_lexical_path_and_publishes_target(self):
        physical = self.write_root / "physical"
        physical.mkdir()
        alias = self.write_root / "alias"
        alias.symlink_to(physical, target_is_directory=True)
        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document["output"]["path"] = str(alias / "export.jpg")
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertTrue(result.ok, str(result.error))
        self.assertEqual(result.result["output_path"], str(alias / "export.jpg"))
        self.assertEqual((physical / "export.jpg").read_bytes(), b"fake-pixels")
        self.assertFalse((alias / "export.jpg").is_symlink())

    async def test_output_parent_redirect_cleans_stage_at_original_canonical_parent(self):
        original = self.write_root / "physical-original"
        redirected = self.write_root / "physical-redirected"
        original.mkdir()
        redirected.mkdir()
        alias = self.write_root / "alias"
        alias.symlink_to(original, target_is_directory=True)
        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document["output"]["path"] = str(alias / "export.jpg")
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
        pid_log = self.root / "pid"
        adapter = self.adapter(FAKE_SLEEP="0.2", FAKE_PID_LOG=str(pid_log))
        await adapter.start()
        task = asyncio.create_task(adapter.export_photo(self.recipe_path))
        async with asyncio.timeout(3):
            while not pid_log.exists():
                await asyncio.sleep(0.01)
        alias.unlink()
        alias.symlink_to(redirected, target_is_directory=True)
        result = await task
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "output_io_error")
        self.assertFalse((original / "export.jpg").exists())
        self.assertFalse((redirected / "export.jpg").exists())
        self.assertEqual(list(original.glob(".rawlab-mcp-*")), [])
        self.assertEqual(list(redirected.glob(".rawlab-mcp-*")), [])

    def test_configuration_requires_absolute_paths_and_executable(self):
        with self.assertRaisesRegex(ValueError, "absolute"):
            ServerConfig(Path("sony2fuji"), (self.read_root,), (self.write_root,))
        with self.assertRaisesRegex(ValueError, "absolute"):
            ServerConfig(self.cli, (Path("photos"),), (self.write_root,))
        if os.name == "posix":
            self.cli.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "executable"):
                ServerConfig(self.cli, (self.read_root,), (self.write_root,))

    async def test_recipe_parent_segments_follow_cli_lexical_resolution(self):
        nested = self.read_root / "elsewhere" / "nested"
        nested.mkdir(parents=True)
        (self.recipe_dir / "shortcut").symlink_to(nested, target_is_directory=True)
        document = json.loads(self.recipe_path.read_text())
        document["input"]["path"] = "shortcut/../" + self.input_path.name
        self.recipe_path.write_text(json.dumps(document))
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertTrue(result.ok, str(result.error))
        self.assertEqual(json.loads(self.recipe_log.read_text())["input"]["path"], str(self.input_path))

    async def test_validation_does_not_treat_output_symlink_as_a_write(self):
        (self.write_root / "export.jpg").symlink_to(self.write_root / "not-created.jpg")
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.validate_recipe(self.recipe_path)
        self.assertTrue(result.ok, str(result.error))


if __name__ == "__main__":
    unittest.main()
