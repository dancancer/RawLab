import asyncio
import errno
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import anyio
from unittest.mock import patch
from pathlib import Path

from subprocess_support import python_cli_patch


SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

import rawlab_mcp.adapter as adapter_module  # noqa: E402
from rawlab_mcp.adapter import AdapterError, CliAdapter  # noqa: E402
from rawlab_mcp.config import ServerConfig  # noqa: E402
import rawlab_mcp.gui_sync as gui_sync  # noqa: E402


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

            if "--analyze" in args:
                if os.environ.get("FAKE_ANALYZE_JSON"):
                    emit(envelope("analyze", json.loads(os.environ["FAKE_ANALYZE_JSON"])))
                target = args[args.index("--input") + 1] if "--input" in args else args[args.index("--recipe") + 1]
                samples = [args[i + 1] for i, a in enumerate(args) if a == "--sample" and i + 1 < len(args)]
                long_edge = int(args[args.index("--long-edge") + 1]) if "--long-edge" in args else 1024
                emit(envelope("analyze", {
                    "target": target,
                    "long_edge": long_edge,
                    "dimensions": {"width": 16, "height": 12, "bit_depth": 16, "channels": 3, "sampled_pixels": 192},
                    "luma_zones": {"mean_luma_0_1": 0.45, "shadows_10_35_pct": 25.0, "midtones_35_65_pct": 50.0, "highlights_90_100_pct": 5.0},
                    "color_balance": {"r_over_g": 1.01, "b_over_g": 0.99, "cast_hint": "neutral"},
                    "saturation": {"mean_s_pct": 24.0},
                    "hsl_channels": [],
                    "samples": [{"raw": s} for s in samples],
                    "auto_diagnostics": [],
                }))

            if "--save-preset" in args:
                req = json.loads(pathlib.Path(args[args.index("--request") + 1]).read_text(encoding="utf-8"))
                data_dir = pathlib.Path(req["data_dir"])
                presets_file = data_dir / "Presets" / "presets.json"
                if os.environ.get("FAKE_GUI_ERROR") == "duplicate":
                    emit(envelope("save_preset", error={"code": "invalid_argument", "message": "Preset already exists", "status": 2}), 2)
                presets_file.parent.mkdir(parents=True, exist_ok=True)
                presets_file.write_text(json.dumps({"registry_version": 1, "presets": [{"name": req["name"], "values": req["values"]}]}), encoding="utf-8")
                emit(envelope("save_preset", {
                    "action": "updated" if req.get("overwrite") else "created",
                    "id": "00000000-0000-4000-8000-000000000001",
                    "name": req["name"].strip(),
                    "presets_file": str(presets_file),
                }))

            if "--sync-photo-edit" in args:
                req = json.loads(pathlib.Path(args[args.index("--request") + 1]).read_text(encoding="utf-8"))
                if sys.platform not in ("darwin", "win32") or os.environ.get("FAKE_GUI_ERROR") == "unsupported":
                    emit(envelope("sync_photo_edit", error={"code": "unsupported", "message": "Unsupported OS", "status": 4}), 4)
                data_dir = pathlib.Path(req["data_dir"])
                edits_file = data_dir / "Edits" / "edits.json"
                edits_file.parent.mkdir(parents=True, exist_ok=True)
                edits_file.write_text(json.dumps({"version": 1, "records": {req["photo_path"]: req["adjustments"]}}), encoding="utf-8")
                emit(envelope("sync_photo_edit", {
                    "action": "created",
                    "photo_path": req["photo_path"],
                    "edits_file": str(edits_file),
                    "filmID": "" if req.get("master_recipe_id") else req.get("film_id", ""),
                    "masterRecipeID": req.get("master_recipe_id"),
                }))

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
        if os.name == "nt":
            launcher = python_cli_patch()
            launcher.start()
            self.addCleanup(launcher.stop)
        merged = {
            "FAKE_ARGV_LOG": str(self.argv_log),
            "FAKE_RECIPE_LOG": str(self.recipe_log),
            "RAWLAB_MCP_TEST_CLI_SCRIPT": str(self.cli),
        }
        merged.update(env)
        return CliAdapter(self.config, environment=merged)

    async def test_capabilities_negotiate_hdr_recipe_versions(self):
        adapter = self.adapter(
            FAKE_VERSIONS="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20",
            FAKE_COMMANDS="capabilities,validate_recipe,info,preview,export,analyze,print_transfer",
        )
        capabilities = await adapter.start()
        self.assertEqual(capabilities.recipe_versions, tuple(range(1, 21)))
        self.assertEqual(capabilities.result["recipe_versions"], list(range(1, 21)))
        self.assertEqual(capabilities.result["commands"], [
            "capabilities", "validate_recipe", "info", "preview", "export", "analyze", "print_transfer",
        ])

    async def test_lens_database_is_read_root_scoped_and_forwarded(self):
        database = self.read_root / "镜头 database"
        database.mkdir()
        for path in (database, self.look_path):
            self.config = ServerConfig(self.cli, (self.read_root,), (self.write_root,), 2.0,
                                       lens_database=path)
            adapter = self.adapter()
            await adapter.start()
            self.addAsyncCleanup(adapter.close)
            for command in ("preview", "export"):
                destination = self.write_root / f"{path.name}-{command}.png"
                if command == "preview":
                    result = await adapter.render_preview(self.recipe_path, destination)
                else:
                    document = json.loads(self.recipe_path.read_text())
                    document["output"]["path"] = str(destination)
                    self.recipe_path.write_text(json.dumps(document))
                    result = await adapter.export_photo(self.recipe_path)
                self.assertTrue(result.ok, result.error)
                argv = json.loads(self.argv_log.read_text())
                self.assertEqual(argv[argv.index("--lens-database") + 1], str(path.resolve()))
        outside = self.root / "outside"
        outside.mkdir()
        link = self.read_root / "escape"
        link.symlink_to(outside, target_is_directory=True)
        for path in (outside, link, Path("relative.xml"), self.read_root / "missing.xml"):
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                ServerConfig(self.cli, (self.read_root,), (self.write_root,), lens_database=path)

    async def test_v14_camera_profile_is_checked_and_resolved_before_staging(self):
        document = json.loads(self.recipe_path.read_text())
        document.update(schema_version=14, processing={"family": "rawlab_hdr", "version": 7, "quality": "standard"})
        profile = self.recipe_dir / "camera.dcp"
        profile.write_bytes(b"profile fixture")
        document["input"]["camera_development"] = {"camera_profile": {"path": "camera.dcp", "sha256": "a" * 64}}
        self.recipe_path.write_text(json.dumps(document))
        adapter = self.adapter(FAKE_VERSIONS="4,14")
        await adapter.start()
        self.addAsyncCleanup(adapter.close)
        result = await adapter.export_photo(self.recipe_path)
        self.assertTrue(result.ok, result.error)
        staged = json.loads(self.recipe_log.read_text())
        self.assertEqual(staged["input"]["camera_development"]["camera_profile"]["path"], str(profile))
        outside = self.root / "outside.dcp"
        outside.write_bytes(b"outside")
        profile.unlink()
        profile.symlink_to(outside)
        result = await adapter.validate_recipe(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "invalid_argument")

    async def test_v7_x3f_identity_survives_staging_and_requires_capability(self):
        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document.update({
            "schema_version": 7,
            "x3f_mode": "normal-v1",
            "processing": {"family": "rawlab", "version": 1, "quality": "standard"},
            "input": {"path": self.input_path.name, "type": "raw"},
        })
        document["output"]["path"] = str(self.write_root / "x3f.jpg")
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")

        old = self.adapter(FAKE_VERSIONS="1,2,3,4,5,6")
        await old.start()
        refused = await old.export_photo(self.recipe_path)
        self.assertFalse(refused.ok)
        self.assertEqual(refused.error.code, "invalid_argument")
        self.assertFalse((self.write_root / "x3f.jpg").exists())

        adapter = self.adapter(FAKE_VERSIONS="1,2,3,4,5,6,7")
        await adapter.start()
        self.assertTrue((await adapter.validate_recipe(self.recipe_path)).ok)
        self.assertTrue((await adapter.export_photo(self.recipe_path)).ok)
        staged = json.loads(self.recipe_log.read_text(encoding="utf-8"))
        for key in ("schema_version", "x3f_mode", "processing"):
            self.assertEqual(staged[key], document[key])
        self.assertEqual(staged["input"]["type"], document["input"]["type"])

    async def test_v6_hdr_identity_survives_staging_and_requires_capability(self):
        document={"schema_version":6,
            "processing":{"family":"rawlab_hdr","version":1,"quality":"standard"},
            "input":{"path":self.input_path.name,"type":"hdr_raster"},
            "edits":{"exposure":{"ev":1},"white_balance":{"mode":"relative",
                "relative_temperature":7200,"relative_tint":-12},"tone":{"highlights":-.25}},
            "output":{"path":str(self.write_root / "hdr.jpg"),"format":"hdr_jpeg","base_color":"display_p3"}}
        for version, legacy, current in (
            (6, "1,2,3,4,5", "1,2,3,4,5,6"),
            (8, "1,2,3,4,5,6", "1,2,3,4,5,6,8"),
            (9, "1,2,3,4,5,6,8", "1,2,3,4,5,6,8,9"),
            (10, "1,2,3,4,5,6,8,9", "1,2,3,4,5,6,8,9,10"),
            (11, "1,2,3,4,5,6,8,9,10", "1,2,3,4,5,6,8,9,10,11"),
            (12, "1,2,3,4,5,6,8,9,10,11", "1,2,3,4,5,6,8,9,10,11,12"),
            (13, "1,2,3,4,5,6,8,9,10,11,12", "1,2,3,4,5,6,8,9,10,11,12,13"),
            (14, "1,2,3,4,5,6,8,9,10,11,12,13", "1,2,3,4,5,6,8,9,10,11,12,13,14"),
            (15, "1,2,3,4,5,6,8,9,10,11,12,13,14", "1,2,3,4,5,6,8,9,10,11,12,13,14,15"),
        ):
            with self.subTest(version=version):
                destination = self.write_root / f"hdr-{version}.jpg"
                document["schema_version"] = version
                document["output"]["path"] = str(destination)
                if version == 8:
                    document["processing"]["version"] = 2
                    document["edits"]["tone"].update(white_point=.25, curve={"mode": "custom", "points": [[0, 0], [.5, .6], [1, 1]]})
                if version == 9:
                    document["processing"]["version"] = 3
                    document["edits"]["color"] = {"vibrance": -.3}
                    document["edits"]["hsl"] = {"saturation": [10] * 8}
                    document["edits"]["color_grading"] = {"shadows": {"hue": 220, "saturation": 35}}
                if version == 10:
                    document["processing"]["version"] = 4
                    document["edits"]["rendition"] = {"peak_limit_ev": 2, "sdr_exposure_ev": -.75}
                if version == 11:
                    document["processing"]["version"] = 5
                    document["edits"]["effects"] = {"vignette_amount": -60, "grain_amount": 55}
                if version == 12:
                    document["processing"]["version"] = 6
                    document["edits"]["detail"] = {"sharpening": 1.2, "clarity": .7, "dehaze": -.5, "denoise": .6}
                if version == 13:
                    document["processing"]["version"] = 7
                    look = self.input_path.with_suffix(".cube")
                    look.write_text("declared HDR fixture", encoding="utf-8")
                    document["edits"]["look"] = {"path": str(look), "sha256": "a" * 64, "strength": .8}
                if version == 15:
                    document["processing"]["version"] = 8
                    document["edits"]["tone"]["curve"]["channels"] = {"red": {"mode": "custom", "points": [[0, 0], [.5, .7], [1, 1]]}}
                self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
                old = self.adapter(FAKE_VERSIONS=legacy)
                await old.start()
                self.assertFalse((await old.export_photo(self.recipe_path)).ok)
                self.assertFalse(destination.exists())
                adapter = self.adapter(FAKE_VERSIONS=current)
                await adapter.start()
                self.assertTrue((await adapter.validate_recipe(self.recipe_path)).ok)
                exported = await adapter.export_photo(self.recipe_path)
                self.assertTrue(exported.ok, exported.error)
                staged = json.loads(self.recipe_log.read_text(encoding="utf-8"))
                for key in ("schema_version", "processing", "edits"):
                    self.assertEqual(staged[key], document[key])
                self.assertEqual(staged["input"]["type"], "hdr_raster")
                self.assertEqual(staged["output"]["format"], "hdr_jpeg")
                self.assertEqual(staged["output"]["base_color"], "display_p3")

    async def test_capabilities_reject_cli_without_v4(self):
        adapter = self.adapter(FAKE_VERSIONS="1,2,3")
        with self.assertRaisesRegex(AdapterError, "schema version 4"):
            await adapter.start()

    async def test_v5_processing_identity_survives_private_staging(self):
        adapter = self.adapter(FAKE_VERSIONS="1,2,3,4,5")
        await adapter.start()
        for version in (1, 2):
            document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
            document["schema_version"] = 5
            document["processing"] = {"family": "rawlab", "version": version, "quality": "standard"}
            document["output"]["path"] = str(self.write_root / f"version-{version}.png")
            self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
            self.assertTrue((await adapter.validate_recipe(self.recipe_path)).ok)
            self.assertTrue((await adapter.export_photo(self.recipe_path)).ok)
            staged = json.loads(self.recipe_log.read_text(encoding="utf-8"))
            self.assertEqual(staged["processing"], document["processing"])
            self.assertEqual(staged["schema_version"], 5)

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
        invalid_paths = tuple(str(self.input_path) + suffix for suffix in ("\x00tail", "\ud800", "\udcff"))
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
        self.input_path.unlink()
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

    async def test_missing_output_parent_uses_adapter_policy_without_staging(self):
        document = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        document["output"]["path"] = "../../write/missing/export.jpg"
        self.recipe_path.write_text(json.dumps(document), encoding="utf-8")
        adapter = self.adapter()
        await adapter.start()
        result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual((result.error.code, result.error.status), ("invalid_argument", None))
        self.assertFalse((self.write_root / "missing" / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_malformed_and_future_recipes_are_rejected_before_cli(self):
        adapter = self.adapter()
        await adapter.start()
        self.argv_log.unlink()
        for value in ("{bad json", "null", "[]", '{"schema_version":6}', '{"schema_version":true}'):
            self.recipe_path.write_text(value, encoding="utf-8")
            self.assertFalse((await adapter.export_photo(self.recipe_path)).ok)
        self.assertIn("--print-recipe", json.loads(self.argv_log.read_text()))

    async def test_publish_failure_cleans_private_files(self):
        adapter = self.adapter()
        await adapter.start()
        with patch.object(adapter_module, "_publish", side_effect=PermissionError("permission denied")):
            result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "output_io_error")
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_windows_publish_uses_no_clobber_rename_without_hardlink(self):
        staged = self.root / "staged.jpg"
        destination = self.write_root / "export.jpg"
        staged.write_bytes(b"fake-pixels")
        with patch.object(adapter_module.os, "name", "nt"), \
                patch.object(adapter_module.os, "rename") as rename, \
                patch.object(adapter_module.os, "link") as link:
            await adapter_module._publish(staged, destination)
        rename.assert_called_once_with(staged, destination)
        link.assert_not_called()

    async def test_publish_on_volume_without_hard_links(self):
        staged = self.root / "staged.jpg"
        destination = self.write_root / "export.jpg"
        staged.write_bytes(b"fake-pixels")
        unsupported = OSError(errno.ENOTSUP, "operation unsupported")
        with patch.object(adapter_module.os, "name", "posix"), \
                patch.object(adapter_module.os, "link", side_effect=unsupported):
            await adapter_module._publish(staged, destination)
            staged.write_bytes(b"second-render")
            with self.assertRaises(FileExistsError):
                await adapter_module._publish(staged, destination)
        self.assertEqual(destination.read_bytes(), b"fake-pixels")

    @unittest.skipUnless(os.name == "posix", "hard-link fallback is exercised on POSIX")
    async def test_fallback_copy_does_not_block_event_loop(self):
        adapter = self.adapter()
        await adapter.start()
        unsupported = OSError(errno.ENOTSUP, "operation unsupported")
        loop = asyncio.get_running_loop()
        copy_started = asyncio.Event()
        copy_finished = threading.Event()
        release = threading.Event()
        monitor_seen = asyncio.Event()

        def slow_copy(source, output):
            loop.call_soon_threadsafe(copy_started.set)
            # 超时只为错误的同步实现兜底；正常路径由事件循环确认后放行。
            release.wait(1)
            output.write(source.read())
            copy_finished.set()

        async def monitor_copy():
            await copy_started.wait()
            if not copy_finished.is_set():
                monitor_seen.set()
            release.set()

        monitor = asyncio.create_task(monitor_copy())
        try:
            with patch.object(adapter_module.os, "link", side_effect=unsupported), \
                    patch.object(adapter_module.shutil, "copyfileobj", side_effect=slow_copy):
                result = await adapter.export_photo(self.recipe_path)
        finally:
            release.set()
            monitor.cancel()
            await asyncio.gather(monitor, return_exceptions=True)
        self.assertTrue(result.ok, str(result.error))
        self.assertTrue(monitor_seen.is_set(), "fallback copy blocked the event loop")

    @unittest.skipUnless(os.name == "posix", "hard-link fallback is exercised on POSIX")
    async def test_cancellation_waits_for_fallback_copy_before_cleanup(self):
        adapter = self.adapter()
        await adapter.start()
        unsupported = OSError(errno.ENOTSUP, "operation unsupported")
        copy_started = threading.Event()
        copy_finished = threading.Event()
        release = threading.Event()

        def blocked_copy(source, output):
            copy_started.set()
            release.wait(1)
            output.write(source.read())
            copy_finished.set()

        release_timer = threading.Timer(0.3, release.set)
        release_timer.start()
        try:
            with patch.object(adapter_module.os, "link", side_effect=unsupported), \
                    patch.object(adapter_module.shutil, "copyfileobj", side_effect=blocked_copy):
                task = asyncio.create_task(adapter.export_photo(self.recipe_path))
                await asyncio.wait_for(asyncio.to_thread(copy_started.wait), 1)
                task.cancel()
                await asyncio.sleep(0.05)
                self.assertFalse(task.done(), "cancellation did not wait for fallback copy")
                self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
                release.set()
                with self.assertRaises(asyncio.CancelledError):
                    await task
        finally:
            release.set()
            release_timer.cancel()
        self.assertTrue(copy_finished.is_set())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    @unittest.skipUnless(os.name == "posix", "hard-link fallback is exercised on POSIX")
    async def test_repeated_cancellation_waits_for_fallback_copy_before_cleanup(self):
        adapter = self.adapter()
        await adapter.start()
        unsupported = OSError(errno.ENOTSUP, "operation unsupported")
        copy_started = threading.Event()
        copy_finished = threading.Event()
        release = threading.Event()

        def blocked_copy(source, output):
            copy_started.set()
            release.wait(1)
            output.write(source.read())
            copy_finished.set()

        release_timer = threading.Timer(0.5, release.set)
        release_timer.start()
        try:
            with patch.object(adapter_module.os, "link", side_effect=unsupported), \
                    patch.object(adapter_module.shutil, "copyfileobj", side_effect=blocked_copy):
                task = asyncio.create_task(adapter.export_photo(self.recipe_path))
                await asyncio.wait_for(asyncio.to_thread(copy_started.wait), 1)
                task.cancel()
                await asyncio.sleep(0.05)
                task.cancel()
                await asyncio.sleep(0.05)
                self.assertFalse(task.done(), "repeated cancellation did not wait for fallback copy")
                self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
                release.set()
                with self.assertRaises(asyncio.CancelledError):
                    await task
        finally:
            release.set()
            release_timer.cancel()
        self.assertTrue(copy_finished.is_set())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    @unittest.skipUnless(os.name == "posix", "hard-link fallback is exercised on POSIX")
    async def test_anyio_cancellation_waits_without_spinning(self):
        adapter = self.adapter()
        await adapter.start()
        started = threading.Event()
        finished = threading.Event()
        release = threading.Event()

        def blocked_copy(source, output):
            started.set()
            release.wait(1)
            output.write(source.read())
            finished.set()

        timer = threading.Timer(0.3, release.set)
        timer.start()
        real_shield = asyncio.shield
        try:
            with patch.object(adapter_module.os, "link", side_effect=OSError(errno.ENOTSUP, "unsupported")), \
                    patch.object(adapter_module.shutil, "copyfileobj", side_effect=blocked_copy), \
                    patch.object(adapter_module.asyncio, "shield", wraps=real_shield) as shield:
                async with anyio.create_task_group() as group:
                    group.start_soon(adapter.export_photo, self.recipe_path)
                    await anyio.to_thread.run_sync(started.wait)
                    group.cancel_scope.cancel()
                self.assertLess(shield.call_count, 20, "level cancellation spun while waiting for the worker")
        finally:
            release.set()
            timer.cancel()
        self.assertTrue(finished.is_set())
        self.assertEqual(list(self.write_root.glob(".rawlab-mcp-*")), [])

    async def test_windows_publish_rejects_existing_destination_without_overwrite(self):
        staged = self.root / "staged.jpg"
        destination = self.write_root / "export.jpg"
        staged.write_bytes(b"new-pixels")
        destination.write_bytes(b"keep-me")
        real_rename = os.rename

        def windows_rename(source, target):
            if destination.exists():
                raise FileExistsError(errno.EEXIST, "destination exists", target)
            real_rename(source, target)

        with patch.object(adapter_module.os, "name", "nt"), \
                patch.object(adapter_module.os, "rename", side_effect=windows_rename) as rename:
            with self.assertRaises(FileExistsError):
                await adapter_module._publish(staged, destination)
        rename.assert_called_once_with(staged, destination)
        self.assertEqual(destination.read_bytes(), b"keep-me")
        self.assertEqual(staged.read_bytes(), b"new-pixels")

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
        pid_log = self.root / "timeout-pid"
        adapter = self.adapter(FAKE_SLEEP="5", FAKE_PID_LOG=str(pid_log))
        await adapter.start()
        adapter.config = ServerConfig(self.cli, (self.read_root,), (self.write_root,), timeout=2)
        with patch("rawlab_mcp.adapter.shutil.rmtree", side_effect=OSError("cleanup denied")):
            result = await adapter.export_photo(self.recipe_path)
        self.assertFalse(result.ok)
        self.assertEqual(result.error.code, "processing_error")
        self.assertIn("timed out", result.error.message)
        self.assertTrue(pid_log.exists(), "Timeout must reach the staged render process")
        self.assertFalse((self.write_root / "export.jpg").exists())
        self.assertEqual(len(list(self.write_root.glob(".rawlab-mcp-*"))), 1)
        self.temporary.cleanup()
        self.assertFalse(self.root.exists())

    async def test_cleanup_failure_preserves_cancellation(self):
        pid_log = self.root / "cancel-pid"
        adapter = self.adapter(FAKE_SLEEP="5", FAKE_PID_LOG=str(pid_log))
        await adapter.start()
        task = asyncio.create_task(adapter.export_photo(self.recipe_path))
        async with asyncio.timeout(3):
            while not pid_log.exists():
                await asyncio.sleep(0.01)
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

    async def test_diagnose_image_validates_roots_samples_and_capabilities(self):
        legacy_adapter = self.adapter()
        await legacy_adapter.start()
        unsupported = await legacy_adapter.diagnose_image(image_path=str(self.input_path))
        self.assertFalse(unsupported.ok)
        self.assertEqual(unsupported.error.code, "unsupported")

        adapter = self.adapter(FAKE_COMMANDS="capabilities,validate_recipe,info,preview,export,analyze")
        await adapter.start()

        by_image = await adapter.diagnose_image(
            image_path=str(self.input_path),
            samples=["0.5,0.5,center", "0.2,0.3,sky"],
            long_edge=640,
        )
        self.assertTrue(by_image.ok, str(by_image.error))
        self.assertEqual(by_image.result["long_edge"], 640)
        self.assertEqual(by_image.result["samples"], [{"raw": "0.5,0.5,center"}, {"raw": "0.2,0.3,sky"}])

        # Recipe mode does not require write_root output parent to exist
        doc = json.loads(self.recipe_path.read_text(encoding="utf-8"))
        doc["output"]["path"] = "/nonexistent-dir/out.jpg"
        self.recipe_path.write_text(json.dumps(doc), encoding="utf-8")
        by_recipe = await adapter.diagnose_image(recipe_path=str(self.recipe_path), samples=["0.5,0.5"])
        self.assertTrue(by_recipe.ok, str(by_recipe.error))

        for bad_sample in ("not_a_coord", "1.5,0.5", "-0.1,0.5", "0.5,0.5,  "):
            res = await adapter.diagnose_image(image_path=str(self.input_path), samples=[bad_sample])
            self.assertFalse(res.ok)
            self.assertEqual(res.error.code, "invalid_argument")

        outside = self.root / "outside.dng"
        outside.write_bytes(b"secret")
        escape = self.read_root / "escape.dng"
        escape.symlink_to(outside)
        escaped = await adapter.diagnose_image(image_path=str(escape))
        self.assertFalse(escaped.ok)
        self.assertEqual(escaped.error.code, "invalid_argument")

    async def test_diagnose_image_enriches_portrait_and_auto_diagnostics(self):
        payload = {
            "dimensions": {"width": 64, "height": 64, "bit_depth": 16, "channels": 4, "sampled_pixels": 4096},
            "luma_zones": {
                "blacks_0_10_pct": 0.4,
                "shadows_10_35_pct": 12.0,
                "midtones_35_65_pct": 52.0,
                "lights_65_90_pct": 28.0,
                "highlights_90_100_pct": 7.6,
                "mean_luma_0_1": 0.5,
                "percentiles_0_1": {"p01": 0.08, "p05": 0.18, "p25": 0.35, "p50": 0.5, "p75": 0.7, "p95": 0.92, "p99": 0.98},
                "percentiles_0_255": {"p01": 20, "p05": 46, "p50": 128, "p95": 235, "p99": 250},
                "dynamic_spread_p95_minus_p05": 0.74,
            },
            "clipping": {
                "shadow_crush_pct": 0.2,
                "white_blowout_pct": 2.4,
                "channel_clip_high_pct": {"any": 4.1, "r": 3.5, "g": 2.8, "b": 1.2},
            },
            "color_balance": {"neutral_midtone_coverage_pct": 18.0, "r_over_g": 0.92, "b_over_g": 0.94, "cast_hint": "green_cast"},
            "saturation": {"mean_s_pct": 25.0, "p95_s_pct": 68.0, "low_sat_pct": 20.0, "melting_saturation_pct": 3.2, "melting_warning": True},
            "hsl_channels": {},
            "samples": [
                {"label": "center", "hsb": {"h_deg": 20.0, "s_pct": 25.0, "b_pct": 78.0}},
                {"label": "face_in_window", "hsb": {"h_deg": 20.0, "s_pct": 25.0, "b_pct": 78.0}},
                {"label": "肤色偏黄暗", "hsb": {"h_deg": 31.0, "s_pct": 42.0, "b_pct": 62.0}},
                {"label": "脸颊偏红亮", "hsb": {"h_deg": 11.0, "s_pct": 12.0, "b_pct": 90.0}},
            ],
        }
        adapter = self.adapter(
            FAKE_COMMANDS="capabilities,validate_recipe,info,preview,export,analyze",
            FAKE_ANALYZE_JSON=json.dumps(payload),
        )
        await adapter.start()
        res = await adapter.diagnose_image(image_path=str(self.input_path))
        self.assertTrue(res.ok, str(res.error))
        samples = res.result["samples"]
        self.assertNotIn("portrait_skin_check", samples[0])
        self.assertTrue(samples[1]["portrait_skin_check"]["in_window"])
        self.assertEqual(samples[1]["portrait_skin_check"]["hints"], [])
        self.assertFalse(samples[2]["portrait_skin_check"]["in_window"])
        self.assertEqual(len(samples[2]["portrait_skin_check"]["hints"]), 3)
        self.assertFalse(samples[3]["portrait_skin_check"]["in_window"])
        self.assertEqual(len(samples[3]["portrait_skin_check"]["hints"]), 3)
        alerts = res.result["auto_diagnostics"]
        self.assertEqual(len(alerts), 4)
        self.assertIn("Highlight clipping", alerts[0])
        self.assertIn("Weak dark anchor (p05=0.180", alerts[1])
        self.assertIn("Melting saturation risk", alerts[2])
        self.assertIn("Midtone neutral cast detected (green_cast", alerts[3])

        # Also verify shadow crush + magenta cast branch
        payload["clipping"]["shadow_crush_pct"] = 4.5
        payload["color_balance"]["cast_hint"] = "magenta_cast"
        adapter2 = self.adapter(
            FAKE_COMMANDS="capabilities,validate_recipe,info,preview,export,analyze",
            FAKE_ANALYZE_JSON=json.dumps(payload),
        )
        await adapter2.start()
        res2 = await adapter2.diagnose_image(image_path=str(self.input_path))
        self.assertTrue(res2.ok)
        self.assertIn("Shadow crush (4.5%", res2.result["auto_diagnostics"][1])
        self.assertIn("magenta_cast", res2.result["auto_diagnostics"][3])

    async def test_list_catalog_looks_filters_and_isolates(self):
        adapter = self.adapter()
        await adapter.start()
        all_looks = await adapter.list_catalog_looks()
        self.assertTrue(all_looks.ok)
        counts = all_looks.result["counts"]
        self.assertEqual(counts["master_recipe"], 14)
        self.assertEqual(counts["bundled"], 29)
        self.assertEqual(counts["fuji_flog2"], 16)
        self.assertEqual(counts["hdr"], 1)

        recipes_only = await adapter.list_catalog_looks(category="master_recipe", query="hamada")
        self.assertTrue(recipes_only.ok)
        self.assertEqual(len(recipes_only.result["looks"]), 1)
        self.assertEqual(recipes_only.result["looks"][0]["id"], "hamada_daylight_v2")

    async def test_gui_sync_tools_require_opt_in_and_enforce_controlled_data_dir(self):
        # Default config disables GUI sync tools
        adapter = self.adapter()
        await adapter.start()
        denied_preset = await adapter.save_preset(name="Test", values={"light.exposure": 0.5})
        self.assertFalse(denied_preset.ok)
        self.assertEqual(denied_preset.error.code, "unsupported")
        denied_sync = await adapter.sync_photo_edit(photo_path=str(self.input_path), adjustments={"exposure": 0.5})
        self.assertFalse(denied_sync.ok)
        self.assertEqual(denied_sync.error.code, "unsupported")

        data_dir = self.root / "appdata"
        gui_config = ServerConfig(
            cli=self.cli,
            read_roots=(self.read_root,),
            write_roots=(self.write_root,),
            timeout=2.0,
            enable_gui_sync=True,
            data_dir=data_dir,
        )
        gui_adapter = CliAdapter(gui_config, environment={
            "FAKE_ARGV_LOG": str(self.argv_log),
            "FAKE_RECIPE_LOG": str(self.recipe_log),
            "RAWLAB_MCP_TEST_CLI_SCRIPT": str(self.cli),
        })
        await gui_adapter.start()

        # Adapter forwards save_preset request via --save-preset --request ... --json
        created = await gui_adapter.save_preset(
            name="  Agent  Look\u00a0",
            values={
                "light.exposure": 0.4,
                "light.curve.apply_to_luminosity": True,
                "color.grading.balance": -12.0,
            },
        )
        self.assertTrue(created.ok, str(created.error))
        self.assertEqual(created.result["action"], "created")
        argv_logged = json.loads(self.argv_log.read_text(encoding="utf-8"))
        self.assertEqual(argv_logged[0], "--save-preset")
        self.assertEqual(argv_logged[1], "--request")
        self.assertEqual(argv_logged[-1], "--json")

        # Symlink escape in Presets/ must be rejected before invoking CLI
        outside = self.root / "outside-presets"
        outside.mkdir()
        escaped_data = self.root / "escaped-appdata"
        escaped_data.mkdir()
        (escaped_data / "Presets").symlink_to(outside, target_is_directory=True)
        escaped_adapter = CliAdapter(ServerConfig(
            cli=self.cli, read_roots=(self.read_root,), write_roots=(self.write_root,),
            timeout=2.0, enable_gui_sync=True, data_dir=escaped_data,
        ), environment={
            "FAKE_ARGV_LOG": str(self.argv_log), "FAKE_RECIPE_LOG": str(self.recipe_log),
            "RAWLAB_MCP_TEST_CLI_SCRIPT": str(self.cli),
        })
        await escaped_adapter.start()
        symlink_rejected = await escaped_adapter.save_preset(name="Escape", values={"light.exposure": 0.1})
        self.assertFalse(symlink_rejected.ok)
        self.assertEqual(symlink_rejected.error.code, "invalid_argument")
        self.assertFalse((outside / "presets.json").exists())

        # Adapter forwards CLI error status cleanly
        err_adapter = CliAdapter(gui_config, environment={
            "FAKE_ARGV_LOG": str(self.argv_log),
            "FAKE_RECIPE_LOG": str(self.recipe_log),
            "RAWLAB_MCP_TEST_CLI_SCRIPT": str(self.cli),
            "FAKE_GUI_ERROR": "duplicate",
        })
        await err_adapter.start()
        dup_err = await err_adapter.save_preset(name="Dup", values={"light.exposure": 0.1})
        self.assertFalse(dup_err.ok)
        self.assertEqual(dup_err.error.code, "invalid_argument")
        self.assertEqual(dup_err.error.status, 2)

        # Adapter forwards sync_photo_edit via --sync-photo-edit --request ... --json and enforces read_roots
        outside_photo = self.root / "outside-photo.ARW"
        outside_photo.write_bytes(b"RAW")
        out_of_root = await gui_adapter.sync_photo_edit(photo_path=str(outside_photo), adjustments={"exposure": 0.5})
        self.assertFalse(out_of_root.ok)
        self.assertEqual(out_of_root.error.code, "invalid_argument")

        sync_res = await gui_adapter.sync_photo_edit(
            photo_path=str(self.input_path),
            adjustments={"exposure": 0.65},
            film_id="builtin:classic_chrome",
        )
        if sys.platform in ("darwin", "win32"):
            self.assertTrue(sync_res.ok, str(sync_res.error))
            argv_sync = json.loads(self.argv_log.read_text(encoding="utf-8"))
            self.assertEqual(argv_sync[0], "--sync-photo-edit")
            self.assertEqual(argv_sync[1], "--request")
            self.assertEqual(argv_sync[-1], "--json")
            self.assertEqual(sync_res.result["filmID"], "builtin:classic_chrome")
        else:
            self.assertFalse(sync_res.ok)
            self.assertEqual(sync_res.error.code, "unsupported")

    def test_transfer_spec_matches_shared_adjustment_fields_v1(self):
        repo_root = Path(__file__).resolve().parents[3]
        spec_path = repo_root / "Shared" / "specs" / "adjustment-fields-v1.json"
        self.assertTrue(spec_path.is_file(), f"Missing spec at {spec_path}")
        full_spec = json.loads(spec_path.read_text(encoding="utf-8"))
        bundled = json.loads(gui_sync.BUNDLED_TRANSFER_SPEC_PATH.read_text(encoding="utf-8"))
        self.assertEqual(bundled["spec_version"], full_spec["spec_version"])
        expected_fields = {
            entry["field_id"]: {
                "value_type": entry["protocol"]["value_type"],
                "nullable": bool(entry["protocol"]["nullable"]),
                "min": entry["protocol"]["min"],
                "max": entry["protocol"]["max"],
                "exclusive_min": bool(entry["protocol"].get("exclusive_min", False)),
                "exclusive_max": bool(entry["protocol"].get("exclusive_max", False)),
                "non_empty": bool(entry["protocol"].get("non_empty", False)),
                "allowed_values": entry["protocol"].get("allowed_values"),
                "object_keys": entry["protocol"].get("object_keys"),
                "optional_keys": entry["protocol"].get("optional_keys"),
                "hdr_only": bool(entry["protocol"].get("hdr_only", False)),
                "sub_fields": entry["protocol"].get("sub_fields"),
            }
            for entry in full_spec["fields"]
            if entry["protocol"].get("transferable")
        }
        self.assertEqual(bundled["fields"], expected_fields)
        self.assertEqual(gui_sync._TRANSFER_FIELDS, expected_fields)

    def test_default_cli_runner_wraps_missing_oserror_and_timeout(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-runner-") as tmp:
            data_dir = Path(tmp) / "appdata"
            with patch.dict(os.environ, {"RAWLAB_MCP_CLI": str(Path(tmp) / "missing-cli")}):
                with self.assertRaises(AdapterError) as ctx:
                    gui_sync.save_preset(data_dir=data_dir, name="MissingCli", values={"light.exposure": 0.2})
                self.assertEqual(ctx.exception.code, "processing_error")

            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("RAWLAB_MCP_CLI", None)
                with patch("rawlab_mcp.gui_sync.shutil.which", return_value=None):
                    with self.assertRaises(AdapterError) as ctx:
                        gui_sync.save_preset(data_dir=data_dir, name="NoPathCli", values={"light.exposure": 0.2})
                    self.assertEqual(ctx.exception.code, "processing_error")

            fake_bin = Path(tmp) / "fake_cli"
            fake_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_bin.chmod(0o755)
            with patch.dict(os.environ, {"RAWLAB_MCP_CLI": str(fake_bin)}):
                with patch("rawlab_mcp.gui_sync.subprocess.run", side_effect=OSError("boom")):
                    with self.assertRaises(AdapterError) as ctx:
                        gui_sync.save_preset(data_dir=data_dir, name="OsErrCli", values={"light.exposure": 0.2})
                    self.assertEqual(ctx.exception.code, "processing_error")

                with patch("rawlab_mcp.gui_sync.subprocess.run", side_effect=subprocess.TimeoutExpired(["fake_cli"], 30)):
                    with self.assertRaises(AdapterError) as ctx:
                        gui_sync.save_preset(data_dir=data_dir, name="TimeoutCli", values={"light.exposure": 0.2})
                    self.assertEqual(ctx.exception.code, "processing_error")

    async def test_cli_accepts_status_codes_7_and_8(self):
        cli_78 = self.root / "fake_cli_78.py"
        cli_78.write_text(textwrap.dedent("""
            #!/usr/bin/env python3
            import json, os, sys
            args = sys.argv[1:]
            if "--capabilities" in args:
                print(json.dumps({
                    "protocol_version": 1, "command": "capabilities", "ok": True,
                    "result": {"recipe_versions": [4, 17], "commands": ["capabilities", "validate_recipe", "info", "preview", "export"]},
                    "error": None,
                }))
                sys.exit(0)
            mode = os.environ.get("FAKE_STATUS_MODE", "7")
            if mode == "7":
                print(json.dumps({
                    "protocol_version": 1, "command": "info", "ok": False, "result": None,
                    "error": {"code": "cancelled", "message": "Cancelled by caller", "status": 7},
                }))
                sys.exit(7)
            print(json.dumps({
                "protocol_version": 1, "command": "info", "ok": False, "result": None,
                "error": {"code": "ai_not_ready", "message": "AI model not ready", "status": 8},
            }))
            sys.exit(8)
        """).lstrip(), encoding="utf-8")
        cli_78.chmod(0o755)

        for status_str, expected_code, expected_status in (("7", "cancelled", 7), ("8", "ai_not_ready", 8)):
            with python_cli_patch():
                adapter = CliAdapter(ServerConfig(
                    cli=cli_78, read_roots=(self.read_root,), write_roots=(self.write_root,), timeout=2.0,
                ), environment={"FAKE_STATUS_MODE": status_str, "RAWLAB_MCP_TEST_CLI_SCRIPT": str(cli_78)})
                await adapter.start()
                res = await adapter.image_info(image_path=str(self.input_path))
                self.assertFalse(res.ok)
                self.assertIsNotNone(res.error)
                self.assertEqual(res.error.code, expected_code)
                self.assertEqual(res.error.status, expected_status)

    def test_mcp_schema_and_transfer_spec_expose_all_29_v014_fields(self):
        from rawlab_mcp import gui_sync
        from rawlab_mcp.server import (
            GUI_SYNC_TOOL_SPECS,
            READ_ONLY_TOOL_SPECS,
            SavePresetArguments,
            SyncPhotoEditArguments,
        )

        specs = gui_sync.transfer_field_specs()
        preset_schema = SavePresetArguments.model_json_schema()
        v014_fields = preset_schema["properties"]["values"]["x_v014_transfer_fields"]
        self.assertEqual(len(v014_fields), 29)
        for fid in v014_fields:
            self.assertIn(fid, specs, f"Missing v0.14.0 field in transfer_field_specs: {fid}")

        # Verify SavePresetArguments & SyncPhotoEditArguments validate nested v0.14.0 payloads cleanly
        parsed_preset = SavePresetArguments(
            name="v0.14.0 Master Check",
            values={
                "color.calibration.shadow_tint": -8.0,
                "color.point_color": {
                    "swatches": [{
                        "src_hue": 20.0, "src_saturation": 0.25, "src_luminance": 0.72,
                        "hue_shift": 2.0, "saturation_shift": -6.0, "luminance_shift": 1.0,
                        "variance": -35.0, "range": 50.0, "hue_range": 45.0,
                        "sat_range": 50.0, "lum_range": 55.0, "enabled": True,
                    }]
                },
                "color.selective_color": {
                    "method": "relative",
                    "bands": {b: {"cyan": 0, "magenta": 0, "yellow": 0, "black": 0}
                              for b in ("reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks")},
                },
                "color.bw.enabled": False,
                "color.bw.mixer": {c: 0 for c in ("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")},
                "effects.texture": 15.0,
                "effects.grain.tone_curve": "negative_asymmetric",
                "effects.grain.format_preset": "135",
                "effects.halation.amount": 18.0,
                "effects.bloom.amount": 12.0,
                "detail.sharpening.luminance_v2": True,
                "detail.sharpening.masking": 60.0,
                "geometry.lens.defringe_purple_amount": 3.5,
            },
        )
        self.assertEqual(parsed_preset.values["effects.grain.format_preset"], "135")

        sync_schema = SyncPhotoEditArguments.model_json_schema()
        adj_keys = sync_schema["properties"]["adjustments"]["x_v014_adjustment_keys"]
        for key in ("texture", "calibration", "point_color", "selective_color", "bw", "sharpen_v2", "film_optics", "photo_effects", "lens_correction"):
            self.assertIn(key, adj_keys)
        parsed_sync = SyncPhotoEditArguments(
            photo_path="/photos/portrait.ARW",
            adjustments={
                "texture": -12.0,
                "calibration": {"red_hue": 4.0},
                "point_color": None,
                "sharpen_v2": {"luminance_v2": True, "masking": 65.0},
            },
        )
        self.assertIsNone(parsed_sync.adjustments["point_color"])

        # Tool descriptions reflect v0.14.0 darkroom capabilities
        self.assertIn("point_color", READ_ONLY_TOOL_SPECS["diagnose_image"][2])
        self.assertIn("v0.14.0", GUI_SYNC_TOOL_SPECS["save_preset"][2])
        self.assertIn("v0.14.0", GUI_SYNC_TOOL_SPECS["sync_photo_edit"][2])


if __name__ == "__main__":
    unittest.main()
