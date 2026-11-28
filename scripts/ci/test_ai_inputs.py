"""Unit and contract tests for scripts/ci/ai-inputs.py and CI replay tensor archive."""
from __future__ import annotations

import contextlib
import copy
import functools
import gzip
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import threading
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]
AI_INPUTS_PATH = ROOT / "scripts/ci/ai-inputs.py"
PACKAGE_PATH = ROOT / "scripts/assets/package_ai_models.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AI_INPUTS = _load("test_target_ai_inputs", AI_INPUTS_PATH)
PACKAGE = _load("test_target_package_ai_models", PACKAGE_PATH)


def _record(data: bytes) -> dict:
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def _add_file(root: Path, relative: str, data: bytes) -> dict:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return _record(data)


def _make_complete_synthetic_tree(root: Path) -> tuple[dict, str]:
    root.mkdir(parents=True, exist_ok=True)
    graphs = {}
    for name in ("raw", "isp", "rgb"):
        graphs[name] = {"file": f"{name}.onnx", **_add_file(root, f"{name}.onnx", f"synthetic {name}\n".encode())}
    blind_rgb_record = {"file": "blind_rgb.onnx", **_add_file(root, "blind_rgb.onnx", b"synthetic blind_rgb\n")}
    (root / "DualDn-LICENSE.txt").write_text("DualDn licence fixture\n", encoding="utf-8")
    (root / "Restormer-LICENSE.txt").write_text("Restormer licence fixture\n", encoding="utf-8")

    def coreml_record(directory: str) -> dict:
        entries = []
        for relative, data in (
            ("model.mil", f"{directory} model".encode()),
            ("weights/weight.bin", f"{directory} weights".encode()),
        ):
            entries.append({"path": relative, **_add_file(root, f"{directory}/{relative}", data)})
        return {"directory": directory, "files": entries}

    manifest = {
        "format_version": 1,
        "graphs": graphs,
        "coreml": {"raw": coreml_record("raw.mlmodelc"), "rgb": coreml_record("rgb.mlmodelc")},
        "blind_rgb": {**blind_rgb_record, "coreml": coreml_record("blind_rgb.mlmodelc")},
    }
    manifest_bytes = (json.dumps(manifest, separators=(",", ":")) + "\n").encode("utf-8")
    (root / "manifest.json").write_bytes(manifest_bytes)
    for index, tensor in enumerate(sorted(PACKAGE.SOURCE_ONLY_TEST_TENSORS)):
        (root / tensor).write_bytes(f"t{index:02d}!".encode("ascii"))
    return manifest, hashlib.sha256(manifest_bytes).hexdigest()


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:  # noqa: A002
        return


def _start_http_server(directory: Path) -> tuple[ThreadingHTTPServer, str, list[str]]:
    requests_log: list[str] = []

    class TrackingHandler(_QuietHandler):
        def do_GET(self) -> None:
            requests_log.append(self.path)
            super().do_GET()

    handler = functools.partial(TrackingHandler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, f"http://{host}:{port}", requests_log


def _write_crafted_tar_gz(specs: list[dict]) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for spec in specs:
                info = tarfile.TarInfo(spec["name"])
                info.mtime = info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mode = 0o755 if spec["kind"] == "directory" else 0o644
                kind = spec["kind"]
                if kind == "directory":
                    info.type = tarfile.DIRTYPE
                    info.size = 0
                    tar.addfile(info)
                elif kind in ("symlink", "hardlink"):
                    info.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
                    info.linkname = spec["linkname"]
                    tar.addfile(info)
                else:
                    data = spec["data"]
                    info.type = tarfile.REGTYPE
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
    return output.getvalue()


def _write_synthetic_ort_nupkg(
    entries: dict[str, bytes],
    *,
    symlinks: dict[str, str] | None = None,
) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
        for name, target in (symlinks or {}).items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            zf.writestr(info, target.encode("utf-8"))
    return output.getvalue()


class CheckedInReplayContractTests(unittest.TestCase):
    def test_checked_in_descriptions_match_manifest_and_are_disjoint(self) -> None:
        catalog = json.loads((ROOT / "Shared/ai-models/catalog.json").read_text(encoding="utf-8"))
        replay = json.loads((ROOT / "scripts/ci/ai-replay-tensors.json").read_text(encoding="utf-8"))
        mac_desc = catalog["platforms"]["macos-arm64"]

        self.assertEqual(mac_desc["manifestSha256"], AI_INPUTS.MANIFEST)
        self.assertEqual(replay["schemaVersion"], 1)
        self.assertEqual(replay["kind"], PACKAGE.REPLAY_KIND)
        self.assertEqual(replay["manifestSha256"], AI_INPUTS.MANIFEST)
        self.assertRegex(replay["archiveSha256"], r"^[0-9a-f]{64}$")
        self.assertGreater(replay["archiveBytes"], 0)
        self.assertEqual(
            replay["archiveName"],
            f"rawlab-ai-replay-tensors-{replay['archiveSha256'][:12]}.tar.gz",
        )
        self.assertEqual(
            replay["url"],
            f"https://github.com/dancancer/RawLab/releases/download/assets-v1/{replay['archiveName']}",
        )

        entries = replay["entries"]
        self.assertEqual({e["path"] for e in entries}, PACKAGE.SOURCE_ONLY_TEST_TENSORS)
        self.assertEqual(replay["unpackedBytes"], sum(e["bytes"] for e in entries))
        for entry in entries:
            self.assertEqual(entry["kind"], "file")
            self.assertGreater(entry["bytes"], 0)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")

        mac_paths = {e["path"] for e in mac_desc["entries"]}
        replay_paths = {e["path"] for e in entries}
        self.assertEqual(mac_paths & replay_paths, set())

        # Replay tensors must not enter Shared/assets-manifest.json or Shared/ai-models/catalog.json.
        assets_manifest = json.loads((ROOT / "Shared/assets-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(set(assets_manifest["groups"]), {"luts", "raw"})
        self.assertNotIn("replay-tensors", catalog.get("platforms", {}))

    def test_build_replay_is_deterministic_and_verifies(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            _, manifest_sha = _make_complete_synthetic_tree(source)
            out1, out2 = root / "out1", root / "out2"
            buf1, buf2 = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(buf1):
                self.assertEqual(
                    PACKAGE.main(["build-replay", "--source", str(source), "--output-dir", str(out1)]),
                    0,
                )
            with contextlib.redirect_stdout(buf2):
                self.assertEqual(
                    PACKAGE.main(["build-replay", "--source", str(source), "--output-dir", str(out2)]),
                    0,
                )
            desc1 = json.loads(buf1.getvalue())
            desc2 = json.loads(buf2.getvalue())
            self.assertEqual(desc1, desc2)
            self.assertEqual(desc1["manifestSha256"], manifest_sha)
            arch1 = out1 / desc1["archiveName"]
            arch2 = out2 / desc2["archiveName"]
            self.assertEqual(arch1.read_bytes(), arch2.read_bytes())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(
                    PACKAGE.main(["verify", "--archive", str(arch1), "--description", str(out1 / f"{arch1.name}.json")]),
                    0,
                )

            # Removing one replay tensor must fail build-replay.
            (source / "raw-b.f32").unlink()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(
                    PACKAGE.main(["build-replay", "--source", str(source), "--output-dir", str(root / "out3")]),
                    2,
                )
            self.assertIn("Missing required replay tensor: raw-b.f32", stderr.getvalue())


class AIInputsRestoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        _, self.manifest_sha = _make_complete_synthetic_tree(self.source)

        self.serve_dir = self.root / "serve"
        self.serve_dir.mkdir()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(
                PACKAGE.main([
                    "build", "--source", str(self.source),
                    "--output-dir", str(self.serve_dir), "--platform", "macos-arm64",
                ]),
                0,
            )
            replay_out = io.StringIO()
            with contextlib.redirect_stdout(replay_out):
                self.assertEqual(
                    PACKAGE.main(["build-replay", "--source", str(self.source), "--output-dir", str(self.serve_dir)]),
                    0,
                )
        model_archive = next(self.serve_dir.glob("rawlab-ai-macos-arm64-*.tar.gz"))
        self.model_archive = model_archive
        self.model_desc = json.loads((self.serve_dir / f"{model_archive.name}.json").read_text(encoding="utf-8"))
        self.replay_desc = json.loads(replay_out.getvalue())
        self.replay_archive = self.serve_dir / self.replay_desc["archiveName"]

        self.server, self.base_url, self.requests = _start_http_server(self.serve_dir)
        self.addCleanup(self._stop_server)

        self.model_desc["url"] = f"{self.base_url}/{self.model_desc['archiveName']}"
        self.replay_desc["url"] = f"{self.base_url}/{self.replay_desc['archiveName']}"

        self.catalog_path = self.root / "catalog.json"
        self.replay_path = self.root / "ai-replay-tensors.json"
        self._write_descriptions(self.model_desc, self.replay_desc)

    def _stop_server(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def _write_descriptions(self, model_desc: dict, replay_desc: dict) -> None:
        catalog = {"schemaVersion": 1, "platforms": {"macos-arm64": model_desc}}
        self.catalog_path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
        self.replay_path.write_text(json.dumps(replay_desc, indent=2) + "\n", encoding="utf-8")

    def _run_ai_inputs(
        self,
        argv: list[str],
        *,
        env: dict[str, str],
        extra_patches: tuple = (),
    ) -> str:
        stdout = io.StringIO()
        clean_env = {
            k: v for k, v in os.environ.items()
            if k not in ("RAWLAB_AI_SHARED_CACHE", "RAWLAB_DUALDN_MODEL_DIR", "GITHUB_ENV")
        }
        clean_env.update(env)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, clean_env, clear=True))
            stack.enter_context(mock.patch.object(AI_INPUTS, "MANIFEST", self.manifest_sha))
            stack.enter_context(mock.patch.object(AI_INPUTS, "CATALOG_PATH", self.catalog_path))
            stack.enter_context(mock.patch.object(AI_INPUTS, "REPLAY_DESCRIPTION_PATH", self.replay_path))
            stack.enter_context(mock.patch.object(AI_INPUTS._PREPARE.time, "sleep", lambda _s: None))
            for cm in extra_patches:
                stack.enter_context(cm)
            stack.enter_context(contextlib.redirect_stdout(stdout))
            AI_INPUTS.main(argv)
        return stdout.getvalue()

    def _complete_dir(self, cache: Path) -> Path:
        return cache / "ai-models" / self.manifest_sha / "complete"

    def _assert_no_complete_or_stage(self, cache: Path) -> None:
        manifest_dir = cache / "ai-models" / self.manifest_sha
        self.assertFalse((manifest_dir / "complete").exists())
        if manifest_dir.exists():
            self.assertEqual(list(manifest_dir.glob(".stage-*")), [])

    def test_fresh_cache_assembles_from_local_http_for_windows_and_macos(self) -> None:
        win_cache = self.root / "cache-win"
        out = self._run_ai_inputs(["--platform", "windows", "--arch", "x86_64"], env={"RAWLAB_AI_SHARED_CACHE": str(win_cache)})
        values = json.loads(out)
        complete = self._complete_dir(win_cache)
        self.assertTrue(complete.is_dir())
        self.assertEqual(values["RAWLAB_DUALDN"], "1")
        self.assertEqual(values["RAWLAB_DUALDN_MODEL_DIR"], str(complete.resolve()))
        self.assertEqual(values["RAWLAB_DUALDN_MANIFEST_SHA256"], self.manifest_sha)
        self.assertEqual(list(complete.parent.glob(".stage-*")), [])

        # Every file in the assembled tree matches the source complete tree.
        expected_files, _ = PACKAGE._walk_model_tree(self.source)
        actual_files, _ = PACKAGE._walk_model_tree(complete)
        self.assertEqual(set(actual_files), set(expected_files))
        for rel in expected_files:
            self.assertEqual((complete / rel).read_bytes(), (self.source / rel).read_bytes(), rel)

        # macOS arm64 assembles the same single-manifest complete directory (with pre-cached synthetic ORT).
        mac_cache = self.root / "cache-mac"
        ort_root = mac_cache / "onnxruntime/1.23.2"
        ort_name = "onnxruntime-osx-arm64-1.23.2"
        ort_lib = ort_root / ort_name / "lib/libonnxruntime.1.23.2.dylib"
        ort_lib.parent.mkdir(parents=True)
        ort_lib.write_bytes(b"synthetic-ort-dylib")
        lib_sha = hashlib.sha256(b"synthetic-ort-dylib").hexdigest()
        mac_out = self._run_ai_inputs(
            ["--platform", "macos", "--arch", "arm64"],
            env={"RAWLAB_AI_SHARED_CACHE": str(mac_cache)},
            extra_patches=(
                mock.patch.dict(AI_INPUTS.ORT_LIBRARY, {"arm64": lib_sha}),
            ),
        )
        mac_values = json.loads(mac_out)
        mac_complete = self._complete_dir(mac_cache)
        self.assertTrue(mac_complete.is_dir())
        self.assertEqual(mac_values["RAWLAB_DUALDN_MODEL_DIR"], str(mac_complete.resolve()))
        self.assertEqual(mac_values["RAWLAB_ONNXRUNTIME_ROOT"], str((ort_root / ort_name).resolve()))

    def test_wrong_archive_size_fails_before_decompression_and_leaves_no_complete(self) -> None:
        for which in ("model", "replay"):
            with self.subTest(archive=which):
                cache = self.root / f"cache-bad-size-{which}"
                model_desc = copy.deepcopy(self.model_desc)
                replay_desc = copy.deepcopy(self.replay_desc)
                target = model_desc if which == "model" else replay_desc
                target["archiveBytes"] += 1
                self._write_descriptions(model_desc, replay_desc)
                with self.assertRaisesRegex(RuntimeError, "Size mismatch"):
                    self._run_ai_inputs(
                        ["--platform", "windows", "--arch", "x86_64"],
                        env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
                        extra_patches=(
                            mock.patch.object(
                                AI_INPUTS._PREPARE,
                                "_safe_extract_tar_gz",
                                side_effect=AssertionError("must not extract bad-size archive"),
                            ) if which == "model" else contextlib.nullcontext(),
                            mock.patch.object(
                                AI_INPUTS._PACKAGE,
                                "_archive_inventory",
                                side_effect=AssertionError("must not parse bad-size archive"),
                            ) if which == "model" else contextlib.nullcontext(),
                        ),
                    )
                self._assert_no_complete_or_stage(cache)

    def test_wrong_archive_sha256_fails_before_decompression_and_leaves_no_complete(self) -> None:
        cache = self.root / "cache-bad-sha"
        model_desc = copy.deepcopy(self.model_desc)
        model_desc["archiveSha256"] = ("0" if model_desc["archiveSha256"][0] != "0" else "1") + model_desc["archiveSha256"][1:]
        self._write_descriptions(model_desc, self.replay_desc)
        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            self._run_ai_inputs(
                ["--platform", "windows", "--arch", "x86_64"],
                env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
                extra_patches=(
                    mock.patch.object(
                        AI_INPUTS._PREPARE,
                        "_safe_extract_tar_gz",
                        side_effect=AssertionError("must not extract bad-sha archive"),
                    ),
                    mock.patch.object(
                        AI_INPUTS._PACKAGE,
                        "_archive_inventory",
                        side_effect=AssertionError("must not parse bad-sha archive"),
                    ),
                ),
            )
        self._assert_no_complete_or_stage(cache)

    def test_archive_member_not_in_description_fails_with_no_complete(self) -> None:
        cache = self.root / "cache-extra-member"
        specs = [
            {"name": name, "kind": "file", "data": (self.source / name).read_bytes()}
            for name in sorted(PACKAGE.SOURCE_ONLY_TEST_TENSORS)
        ]
        specs.append({"name": "zzz-unexpected.f32", "kind": "file", "data": b"evil"})
        crafted_bytes = _write_crafted_tar_gz(specs)
        crafted_sha = hashlib.sha256(crafted_bytes).hexdigest()
        crafted_name = f"rawlab-ai-replay-tensors-{crafted_sha[:12]}.tar.gz"
        (self.serve_dir / crafted_name).write_bytes(crafted_bytes)

        replay_desc = copy.deepcopy(self.replay_desc)
        replay_desc["archiveName"] = crafted_name
        replay_desc["archiveSha256"] = crafted_sha
        replay_desc["archiveBytes"] = len(crafted_bytes)
        replay_desc["url"] = f"{self.base_url}/{crafted_name}"
        self._write_descriptions(self.model_desc, replay_desc)

        with self.assertRaisesRegex(ValueError, "more members than the description"):
            self._run_ai_inputs(["--platform", "windows", "--arch", "x86_64"], env={"RAWLAB_AI_SHARED_CACHE": str(cache)})
        self._assert_no_complete_or_stage(cache)

    def test_link_member_fails_with_no_complete(self) -> None:
        for link_kind in ("symlink", "hardlink"):
            with self.subTest(link_kind=link_kind):
                cache = self.root / f"cache-{link_kind}"
                tensors = sorted(PACKAGE.SOURCE_ONLY_TEST_TENSORS)
                specs = [
                    {"name": name, "kind": "file", "data": (self.source / name).read_bytes()}
                    for name in tensors[:-1]
                ]
                specs.append({"name": tensors[-1], "kind": link_kind, "linkname": tensors[0]})
                crafted_bytes = _write_crafted_tar_gz(specs)
                crafted_sha = hashlib.sha256(crafted_bytes).hexdigest()
                crafted_name = f"rawlab-ai-replay-tensors-{crafted_sha[:12]}.tar.gz"
                (self.serve_dir / crafted_name).write_bytes(crafted_bytes)

                replay_desc = copy.deepcopy(self.replay_desc)
                replay_desc["archiveName"] = crafted_name
                replay_desc["archiveSha256"] = crafted_sha
                replay_desc["archiveBytes"] = len(crafted_bytes)
                replay_desc["url"] = f"{self.base_url}/{crafted_name}"
                self._write_descriptions(self.model_desc, replay_desc)

                with self.assertRaisesRegex(ValueError, "Refusing link member"):
                    self._run_ai_inputs(
                        ["--platform", "windows", "--arch", "x86_64"],
                        env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
                    )
                self._assert_no_complete_or_stage(cache)

    def test_tampered_tensor_content_fails_with_no_complete(self) -> None:
        cache = self.root / "cache-tampered-tensor"
        specs = []
        for name in sorted(PACKAGE.SOURCE_ONLY_TEST_TENSORS):
            data = (self.source / name).read_bytes()
            if name == "raw-b.f32":
                data = b"XXXX"  # same 4-byte size, different content
            specs.append({"name": name, "kind": "file", "data": data})
        crafted_bytes = _write_crafted_tar_gz(specs)
        crafted_sha = hashlib.sha256(crafted_bytes).hexdigest()
        crafted_name = f"rawlab-ai-replay-tensors-{crafted_sha[:12]}.tar.gz"
        (self.serve_dir / crafted_name).write_bytes(crafted_bytes)

        replay_desc = copy.deepcopy(self.replay_desc)
        replay_desc["archiveName"] = crafted_name
        replay_desc["archiveSha256"] = crafted_sha
        replay_desc["archiveBytes"] = len(crafted_bytes)
        replay_desc["url"] = f"{self.base_url}/{crafted_name}"
        self._write_descriptions(self.model_desc, replay_desc)

        with self.assertRaisesRegex(ValueError, "Archive members do not match the description"):
            self._run_ai_inputs(["--platform", "windows", "--arch", "x86_64"], env={"RAWLAB_AI_SHARED_CACHE": str(cache)})
        self._assert_no_complete_or_stage(cache)

    def test_existing_valid_directory_triggers_no_download(self) -> None:
        cache = self.root / "cache-existing-valid"
        complete = self._complete_dir(cache)
        _make_complete_synthetic_tree(complete)
        self.requests.clear()
        out = self._run_ai_inputs(
            ["--platform", "windows", "--arch", "x86_64"],
            env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
            extra_patches=(
                mock.patch.object(
                    AI_INPUTS._PREPARE,
                    "download_with_retry",
                    side_effect=AssertionError("must not download when complete exists"),
                ),
            ),
        )
        values = json.loads(out)
        self.assertEqual(values["RAWLAB_DUALDN_MODEL_DIR"], str(complete.resolve()))
        self.assertEqual(self.requests, [])

    def test_existing_invalid_default_directory_fails_without_overwriting(self) -> None:
        cache = self.root / "cache-existing-invalid"
        complete = self._complete_dir(cache)
        complete.mkdir(parents=True)
        sentinel = complete / "admin-placed.txt"
        sentinel.write_text("do not delete\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Provision the licensed DualDn/Restormer package"):
            self._run_ai_inputs(
                ["--platform", "windows", "--arch", "x86_64"],
                env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
                extra_patches=(
                    mock.patch.object(
                        AI_INPUTS._PREPARE,
                        "download_with_retry",
                        side_effect=AssertionError("must not download over existing directory"),
                    ),
                ),
            )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "do not delete\n")

    def test_explicit_rawlab_dualdn_model_dir_missing_keeps_error_without_download(self) -> None:
        missing = self.root / "explicit-missing"
        with self.assertRaisesRegex(ValueError, "Provision the licensed DualDn/Restormer package"):
            self._run_ai_inputs(
                ["--platform", "windows", "--arch", "x86_64"],
                env={
                    "RAWLAB_AI_SHARED_CACHE": str(self.root / "unused-cache"),
                    "RAWLAB_DUALDN_MODEL_DIR": str(missing),
                },
                extra_patches=(
                    mock.patch.object(
                        AI_INPUTS._PREPARE,
                        "download_with_retry",
                        side_effect=AssertionError("must not download when RAWLAB_DUALDN_MODEL_DIR is set"),
                    ),
                ),
            )
        self.assertFalse(missing.exists())

    def _serve_synthetic_ort_nupkg(
        self,
        filename: str,
        *,
        arm64_dylib: bytes = b"synthetic-arm64-dylib",
        x64_dylib: bytes = b"synthetic-x64-dylib",
        extra_entries: dict[str, bytes] | None = None,
        symlinks: dict[str, str] | None = None,
    ) -> tuple[dict, dict[str, str]]:
        entries = {
            "runtimes/osx-arm64/native/libonnxruntime.dylib": arm64_dylib,
            "runtimes/osx-x64/native/libonnxruntime.dylib": x64_dylib,
            "runtimes/win-x64/native/onnxruntime.dll": b"unused-windows-dll",
            "build/native/include/onnxruntime_cxx_api.h": b"// cxx api\n",
            "build/native/include/onnxruntime_c_api.h": b"// c api\n",
            "LICENSE": b"MIT license fixture\n",
            "ThirdPartyNotices.txt": b"Third-party notices fixture\n",
        }
        if extra_entries:
            entries.update(extra_entries)
        package_bytes = _write_synthetic_ort_nupkg(entries, symlinks=symlinks)
        (self.serve_dir / filename).write_bytes(package_bytes)
        package_spec = {
            "url": f"{self.base_url}/{filename}",
            "archiveName": filename,
            "archiveSha256": hashlib.sha256(package_bytes).hexdigest(),
            "archiveBytes": len(package_bytes),
        }
        lib_pins = {
            "arm64": hashlib.sha256(arm64_dylib).hexdigest(),
            "x86_64": hashlib.sha256(x64_dylib).hexdigest(),
        }
        return package_spec, lib_pins

    def _assert_no_ort_runtime_or_stage(self, cache: Path, arch: str) -> None:
        ort_root = cache / "onnxruntime" / AI_INPUTS.ORT_VERSION
        self.assertFalse((ort_root / f"onnxruntime-osx-{arch}-{AI_INPUTS.ORT_VERSION}").exists())
        if ort_root.exists():
            self.assertEqual(list(ort_root.glob(".stage-*")), [])

    def test_macos_ort_fresh_assembly_from_nuget_for_both_architectures(self) -> None:
        package_spec, lib_pins = self._serve_synthetic_ort_nupkg("ort-valid.nupkg")
        expected_dylibs = {"arm64": b"synthetic-arm64-dylib", "x86_64": b"synthetic-x64-dylib"}
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                cache = self.root / f"cache-ort-fresh-{arch}"
                out = self._run_ai_inputs(
                    ["--platform", "macos", "--arch", arch],
                    env={
                        "RAWLAB_AI_SHARED_CACHE": str(cache),
                        "RAWLAB_DUALDN_MODEL_DIR": str(self.source),
                    },
                    extra_patches=(
                        mock.patch.dict(AI_INPUTS.ORT_PACKAGE, package_spec),
                        mock.patch.dict(AI_INPUTS.ORT_LIBRARY, lib_pins),
                    ),
                )
                values = json.loads(out)
                runtime = cache / "onnxruntime" / AI_INPUTS.ORT_VERSION / f"onnxruntime-osx-{arch}-{AI_INPUTS.ORT_VERSION}"
                self.assertEqual(values["RAWLAB_ONNXRUNTIME_ROOT"], str(runtime.resolve()))
                self.assertEqual(list(runtime.parent.glob(".stage-*")), [])
                self.assertEqual((runtime / "VERSION_NUMBER").read_text(encoding="utf-8"), f"{AI_INPUTS.ORT_VERSION}\n")
                self.assertEqual((runtime / "LICENSE").read_bytes(), b"MIT license fixture\n")
                self.assertEqual((runtime / "ThirdPartyNotices.txt").read_bytes(), b"Third-party notices fixture\n")
                self.assertEqual((runtime / "include/onnxruntime_cxx_api.h").read_bytes(), b"// cxx api\n")
                self.assertEqual((runtime / "include/onnxruntime_c_api.h").read_bytes(), b"// c api\n")
                dylib = runtime / f"lib/libonnxruntime.{AI_INPUTS.ORT_VERSION}.dylib"
                self.assertEqual(dylib.read_bytes(), expected_dylibs[arch])
                self.assertTrue(dylib.stat().st_mode & 0o111)
                symlink = runtime / "lib/libonnxruntime.dylib"
                self.assertTrue(symlink.is_symlink())
                self.assertEqual(os.readlink(symlink), dylib.name)
                self.assertFalse((runtime / "runtimes").exists())
                self.assertFalse((runtime / "build").exists())

    def test_macos_ort_wrong_package_checksum_rejected_before_unpacking(self) -> None:
        package_spec, lib_pins = self._serve_synthetic_ort_nupkg("ort-bad-check.nupkg")
        for field, expected_error in (("archiveSha256", "SHA-256 mismatch"), ("archiveBytes", "Size mismatch")):
            with self.subTest(field=field):
                cache = self.root / f"cache-ort-bad-{field}"
                bad_spec = dict(package_spec)
                if field == "archiveSha256":
                    bad_spec[field] = ("0" if bad_spec[field][0] != "0" else "1") + bad_spec[field][1:]
                else:
                    bad_spec[field] += 1
                with self.assertRaisesRegex(RuntimeError, expected_error):
                    self._run_ai_inputs(
                        ["--platform", "macos", "--arch", "arm64"],
                        env={
                            "RAWLAB_AI_SHARED_CACHE": str(cache),
                            "RAWLAB_DUALDN_MODEL_DIR": str(self.source),
                        },
                        extra_patches=(
                            mock.patch.dict(AI_INPUTS.ORT_PACKAGE, bad_spec),
                            mock.patch.dict(AI_INPUTS.ORT_LIBRARY, lib_pins),
                            mock.patch.object(
                                AI_INPUTS,
                                "_extract_ort_nuget_package",
                                side_effect=AssertionError("must not unpack unverified NuGet package"),
                            ),
                        ),
                    )
                self._assert_no_ort_runtime_or_stage(cache, "arm64")

    def test_macos_ort_library_pin_mismatch_leaves_no_runtime_directory(self) -> None:
        package_spec, lib_pins = self._serve_synthetic_ort_nupkg("ort-bad-lib.nupkg")
        wrong_lib_sha = ("0" if lib_pins["arm64"][0] != "0" else "1") + lib_pins["arm64"][1:]
        cache = self.root / "cache-ort-bad-lib"
        with self.assertRaisesRegex(ValueError, "ONNX Runtime library SHA-256 mismatch"):
            self._run_ai_inputs(
                ["--platform", "macos", "--arch", "arm64"],
                env={
                    "RAWLAB_AI_SHARED_CACHE": str(cache),
                    "RAWLAB_DUALDN_MODEL_DIR": str(self.source),
                },
                extra_patches=(
                    mock.patch.dict(AI_INPUTS.ORT_PACKAGE, package_spec),
                    mock.patch.dict(AI_INPUTS.ORT_LIBRARY, {"arm64": wrong_lib_sha}),
                ),
            )
        self._assert_no_ort_runtime_or_stage(cache, "arm64")

    def test_macos_ort_existing_runtime_directory_used_offline(self) -> None:
        for with_old_tgz in (False, True):
            with self.subTest(with_old_tgz=with_old_tgz):
                cache = self.root / f"cache-ort-existing-{with_old_tgz}"
                ort_root = cache / "onnxruntime" / AI_INPUTS.ORT_VERSION
                runtime = ort_root / f"onnxruntime-osx-arm64-{AI_INPUTS.ORT_VERSION}"
                dylib = runtime / f"lib/libonnxruntime.{AI_INPUTS.ORT_VERSION}.dylib"
                dylib.parent.mkdir(parents=True)
                dylib.write_bytes(b"existing-old-archive-dylib")
                if with_old_tgz:
                    (ort_root / f"{runtime.name}.tgz").write_bytes(b"stale-or-present-tgz")
                lib_sha = hashlib.sha256(b"existing-old-archive-dylib").hexdigest()
                self.requests.clear()
                out = self._run_ai_inputs(
                    ["--platform", "macos", "--arch", "arm64"],
                    env={
                        "RAWLAB_AI_SHARED_CACHE": str(cache),
                        "RAWLAB_DUALDN_MODEL_DIR": str(self.source),
                    },
                    extra_patches=(
                        mock.patch.dict(AI_INPUTS.ORT_LIBRARY, {"arm64": lib_sha}),
                        mock.patch.object(
                            AI_INPUTS._PREPARE,
                            "download_with_retry",
                            side_effect=AssertionError("must not download when runtime directory exists"),
                        ),
                    ),
                )
                values = json.loads(out)
                self.assertEqual(values["RAWLAB_ONNXRUNTIME_ROOT"], str(runtime.resolve()))
                self.assertEqual(self.requests, [])

    def test_macos_ort_refuses_path_traversal_and_symlink_in_nuget(self) -> None:
        cases = (
            (
                "traversal",
                {"build/native/include/../../escape.h": b"evil"},
                None,
                "Refusing unsafe path",
            ),
            (
                "symlink",
                None,
                {"build/native/include/link.h": "/etc/passwd"},
                "Refusing symlink member",
            ),
        )
        for label, extra_entries, symlinks, expected_error in cases:
            with self.subTest(case=label):
                package_spec, lib_pins = self._serve_synthetic_ort_nupkg(
                    f"ort-{label}.nupkg",
                    extra_entries=extra_entries,
                    symlinks=symlinks,
                )
                cache = self.root / f"cache-ort-{label}"
                with self.assertRaisesRegex(ValueError, expected_error):
                    self._run_ai_inputs(
                        ["--platform", "macos", "--arch", "arm64"],
                        env={
                            "RAWLAB_AI_SHARED_CACHE": str(cache),
                            "RAWLAB_DUALDN_MODEL_DIR": str(self.source),
                        },
                        extra_patches=(
                            mock.patch.dict(AI_INPUTS.ORT_PACKAGE, package_spec),
                            mock.patch.dict(AI_INPUTS.ORT_LIBRARY, lib_pins),
                        ),
                    )
                self._assert_no_ort_runtime_or_stage(cache, "arm64")
                self.assertFalse((cache / "onnxruntime" / AI_INPUTS.ORT_VERSION / "escape.h").exists())

    def test_mid_restore_failure_leaves_no_complete_or_staging_dir(self) -> None:
        cache = self.root / "cache-interrupted"
        replay_desc = copy.deepcopy(self.replay_desc)
        replay_desc["url"] = f"{self.base_url}/does-not-exist.tar.gz"
        self._write_descriptions(self.model_desc, replay_desc)
        with self.assertRaisesRegex(RuntimeError, "Failed to download"):
            self._run_ai_inputs(
                ["--platform", "windows", "--arch", "x86_64"],
                env={"RAWLAB_AI_SHARED_CACHE": str(cache)},
            )
        self._assert_no_complete_or_stage(cache)


if __name__ == "__main__":
    unittest.main()
