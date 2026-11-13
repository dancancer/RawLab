"""Verify Shared/fixtures/abi-layout-v1.json stays synchronized with C ABI headers."""
import difflib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Shared/fixtures/generate-abi-layout.sh"
FIXTURE = ROOT / "Shared/fixtures/abi-layout-v1.json"
INCLUDE_DIR = ROOT / "lutools/include"


class AbiLayoutFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cxx = os.environ.get("CXX", "clang++")
        resolved = shutil.which(cxx)
        must_run = (
            os.environ.get("CI") == "true"
            or os.environ.get("GITHUB_ACTIONS") == "true"
            or os.environ.get("RAWLAB_REQUIRE_ABI_CHECK") == "1"
        )
        if not resolved:
            if must_run:
                raise AssertionError(f"Required Clang C++ compiler '{cxx}' not found in PATH")
            raise unittest.SkipTest(f"Clang C++ compiler '{cxx}' not available")
        version = subprocess.run([resolved, "--version"], capture_output=True, text=True)
        if version.returncode != 0 or "clang" not in (version.stdout + version.stderr).lower():
            if must_run:
                raise AssertionError(f"CXX='{cxx}' is not Clang: {version.stdout}{version.stderr}")
            raise unittest.SkipTest(f"CXX='{cxx}' is not Clang")
        cls.cxx = resolved

        with tempfile.TemporaryDirectory(prefix="rawlab-abi-baseline-") as tmp:
            out_path = Path(tmp) / "abi-layout-v1.json"
            cls.baseline_result = cls._run_generator(resolved, out_path, INCLUDE_DIR)
            cls.baseline_text = (
                out_path.read_text(encoding="utf-8") if cls.baseline_result.returncode == 0 else ""
            )

    @staticmethod
    def _run_generator(cxx: str, out_path: Path, include_dir: Path) -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "CXX": cxx,
            "ABI_LAYOUT_OUT": str(out_path),
            "ABI_LAYOUT_INCLUDE_DIR": str(include_dir),
        }
        return subprocess.run(["bash", str(GENERATOR)], env=env, capture_output=True, text=True)

    def regenerate(self, out_path: Path, include_dir: Path = INCLUDE_DIR) -> subprocess.CompletedProcess:
        return self._run_generator(self.cxx, out_path, include_dir)

    def test_committed_fixture_matches_headers(self):
        self.assertEqual(
            self.baseline_result.returncode,
            0,
            self.baseline_result.stdout + self.baseline_result.stderr,
        )
        committed_text = FIXTURE.read_text(encoding="utf-8")
        if committed_text != self.baseline_text:
            diff = "".join(
                difflib.unified_diff(
                    committed_text.splitlines(keepends=True),
                    self.baseline_text.splitlines(keepends=True),
                    fromfile="Shared/fixtures/abi-layout-v1.json",
                    tofile="regenerated/abi-layout-v1.json",
                )
            )
            self.fail(
                "C ABI fixture drift detected (regenerate with `bash Shared/fixtures/generate-abi-layout.sh`):\n"
                + diff
            )

        data = json.loads(self.baseline_text)
        self.assertEqual(data.get("version"), 1)
        self.assertEqual(data.get("fixture_version"), 3)
        self.assertGreaterEqual(len(data.get("structs", [])), 48)
        self.assertGreaterEqual(len(data.get("functions", [])), 95)
        self.assertGreaterEqual(len(data.get("enums", [])), 23)
        self.assertGreaterEqual(len(data.get("callbacks", [])), 4)

        for fn in data["functions"]:
            self.assertEqual(set(fn.keys()), {"name", "return_type", "params", "symbol"})
            self.assertTrue(fn["name"].startswith("sony2fuji_"))
            self.assertEqual(fn["symbol"], fn["name"])
            self.assertIsInstance(fn["params"], list)

        for en in data["enums"]:
            self.assertEqual(set(en.keys()), {"enum", "size", "values"})
            self.assertTrue(en["enum"].startswith("sony2fuji_"))
            self.assertGreater(en["size"], 0)
            self.assertGreater(len(en["values"]), 0)
            for item in en["values"]:
                self.assertEqual(set(item.keys()), {"name", "value"})
                self.assertIsInstance(item["value"], int)

        for cb in data["callbacks"]:
            self.assertEqual(set(cb.keys()), {"name", "return_type", "params"})
            self.assertTrue(cb["name"].startswith("sony2fuji_"))
            self.assertIsInstance(cb["return_type"], str)
            self.assertGreater(len(cb["return_type"]), 0)
            self.assertIsInstance(cb["params"], list)

        expected_callbacks = {
            "sony2fuji_ai_progress_callback": ("int32_t", ["void*", "int32_t", "uint64_t", "uint64_t"]),
            "sony2fuji_cancel_callback": ("int32_t", ["void*"]),
            "sony2fuji_hdr_read_rows_callback": (
                "sony2fuji_status",
                ["void*", "uint32_t", "uint32_t", "uint32_t", "float*"],
            ),
            "sony2fuji_hdr_finish_decode_callback": ("sony2fuji_status", ["void*"]),
        }
        by_name = {cb["name"]: cb for cb in data["callbacks"]}
        self.assertEqual(set(by_name), set(expected_callbacks))
        for name, (ret, params) in expected_callbacks.items():
            self.assertEqual(by_name[name]["return_type"], ret, f"return type of {name}")
            self.assertEqual(by_name[name]["params"], params, f"params of {name}")

    def test_enum_value_drift_is_detected(self):
        self.assertEqual(self.baseline_result.returncode, 0)
        baseline = json.loads(self.baseline_text)
        with tempfile.TemporaryDirectory(prefix="rawlab-abi-enum-") as tmp:
            inc = Path(tmp) / "include"
            shutil.copytree(INCLUDE_DIR, inc)
            c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
            text = c_header.read_text(encoding="utf-8")
            mutated = text.replace(
                "    SONY2FUJI_INTENT_PREVIEW = 0,\n    SONY2FUJI_INTENT_FINAL = 1",
                "    SONY2FUJI_INTENT_PREVIEW = 0,\n    SONY2FUJI_INTENT_PROBE_INSERTED,\n    SONY2FUJI_INTENT_FINAL",
                1,
            )
            self.assertTrue(text != mutated, "Failed to apply enum drift mutation")
            c_header.write_text(mutated, encoding="utf-8")

            out_path = Path(tmp) / "abi-layout-v1.json"
            result = self.regenerate(out_path, inc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            regenerated = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertNotEqual(baseline["enums"], regenerated["enums"])
        intent_enum = next(e for e in regenerated["enums"] if e["enum"] == "sony2fuji_intent")
        self.assertEqual(
            intent_enum["values"],
            [
                {"name": "SONY2FUJI_INTENT_PREVIEW", "value": 0},
                {"name": "SONY2FUJI_INTENT_PROBE_INSERTED", "value": 1},
                {"name": "SONY2FUJI_INTENT_FINAL", "value": 2},
            ],
        )

    def test_function_signature_drift_is_detected(self):
        self.assertEqual(self.baseline_result.returncode, 0)
        baseline = json.loads(self.baseline_text)
        with tempfile.TemporaryDirectory(prefix="rawlab-abi-fn-") as tmp:
            inc = Path(tmp) / "include"
            shutil.copytree(INCLUDE_DIR, inc)
            c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
            text = c_header.read_text(encoding="utf-8")
            mutated = text.replace(
                "void sony2fuji_release_buffer(sony2fuji_buffer* buffer);",
                "void sony2fuji_release_buffer(sony2fuji_buffer* buffer, int32_t flags);",
                1,
            )
            self.assertTrue(text != mutated, "Failed to apply function signature mutation")
            c_header.write_text(mutated, encoding="utf-8")

            out_path = Path(tmp) / "abi-layout-v1.json"
            result = self.regenerate(out_path, inc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            regenerated = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertNotEqual(baseline["functions"], regenerated["functions"])
        fn = next(f for f in regenerated["functions"] if f["name"] == "sony2fuji_release_buffer")
        self.assertEqual(fn["params"], ["sony2fuji_buffer*", "int32_t"])

    def test_callback_prototype_drift_is_detected(self):
        self.assertEqual(self.baseline_result.returncode, 0)
        baseline = json.loads(self.baseline_text)
        with tempfile.TemporaryDirectory(prefix="rawlab-abi-cb-") as tmp:
            inc = Path(tmp) / "include"
            shutil.copytree(INCLUDE_DIR, inc)
            c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
            text = c_header.read_text(encoding="utf-8")
            mutated = text.replace(
                "typedef int32_t (*sony2fuji_cancel_callback)(void* context);",
                "typedef int32_t (*sony2fuji_cancel_callback)(void* context, int32_t reason);",
                1,
            )
            self.assertTrue(text != mutated, "Failed to apply callback prototype mutation")
            c_header.write_text(mutated, encoding="utf-8")

            out_path = Path(tmp) / "abi-layout-v1.json"
            result = self.regenerate(out_path, inc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            regenerated = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertNotEqual(baseline["callbacks"], regenerated["callbacks"])
        cb = next(c for c in regenerated["callbacks"] if c["name"] == "sony2fuji_cancel_callback")
        self.assertEqual(cb["params"], ["void*", "int32_t"])

    def test_qualified_and_aliased_callback_typedefs_are_extracted(self):
        """S1 boundary: cv-qualified and second-level alias typedefs must not be skipped."""
        self.assertEqual(self.baseline_result.returncode, 0)
        baseline = json.loads(self.baseline_text)
        with tempfile.TemporaryDirectory(prefix="rawlab-abi-s1pos-") as tmp:
            inc = Path(tmp) / "include"
            shutil.copytree(INCLUDE_DIR, inc)
            c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
            text = c_header.read_text(encoding="utf-8")
            mutated = text.replace(
                "typedef int32_t (*sony2fuji_cancel_callback)(void* context);",
                "typedef int32_t (*sony2fuji_cancel_callback)(void* context);\n"
                "typedef int32_t (* const sony2fuji_probe_qual_callback)(void* context);\n"
                "typedef sony2fuji_cancel_callback sony2fuji_probe_alias_callback;",
                1,
            )
            self.assertTrue(text != mutated, "Failed to apply qualified/alias typedef mutation")
            c_header.write_text(mutated, encoding="utf-8")

            out_path = Path(tmp) / "abi-layout-v1.json"
            result = self.regenerate(out_path, inc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            regenerated = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertEqual(
            len(regenerated["callbacks"]), len(baseline["callbacks"]) + 2
        )
        by_name = {cb["name"]: cb for cb in regenerated["callbacks"]}
        for probe in ("sony2fuji_probe_qual_callback", "sony2fuji_probe_alias_callback"):
            self.assertIn(probe, by_name, f"{probe} silently dropped by callback extraction")
            self.assertEqual(by_name[probe]["return_type"], "int32_t", probe)
            self.assertEqual(by_name[probe]["params"], ["void*"], probe)

    def test_non_pointer_and_double_pointer_typedefs_are_rejected(self):
        """S1 boundary: plain function typedefs and (**fn) typedefs must fail the contract check."""
        self.assertEqual(self.baseline_result.returncode, 0)
        anchor = "typedef int32_t (*sony2fuji_cancel_callback)(void* context);"
        for label, extra in (
            ("plain", "typedef int32_t sony2fuji_probe_plain_fn(void* context);"),
            ("deep", "typedef int32_t (**sony2fuji_probe_deep_callback)(void* context);"),
        ):
            with tempfile.TemporaryDirectory(prefix=f"rawlab-abi-s1{label}-") as tmp:
                inc = Path(tmp) / "include"
                shutil.copytree(INCLUDE_DIR, inc)
                c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
                text = c_header.read_text(encoding="utf-8")
                mutated = text.replace(anchor, anchor + "\n" + extra, 1)
                self.assertTrue(text != mutated, f"Failed to apply {label} typedef mutation")
                c_header.write_text(mutated, encoding="utf-8")

                result = self.regenerate(Path(tmp) / "abi-layout-v1.json", inc)
                self.assertNotEqual(result.returncode, 0, f"{label} typedef accepted silently")
                self.assertIn(
                    "exactly one pointer level",
                    result.stderr,
                    f"{label} typedef missing contract error: {result.stderr}",
                )

    def test_inline_function_pointer_field_and_param_are_rejected(self):
        """S2 boundary: anonymous inline function pointers must go through a named typedef."""
        self.assertEqual(self.baseline_result.returncode, 0)
        mutations = (
            (
                "param",
                "void sony2fuji_release_buffer(sony2fuji_buffer* buffer);",
                "void sony2fuji_release_buffer(sony2fuji_buffer* buffer, int32_t (*probe_cb)(void* ctx));",
            ),
            (
                "field",
                "    const char* cache_directory;\n} sony2fuji_ai_denoise_config;",
                "    const char* cache_directory;\n"
                "    int32_t (*probe_cb)(void* ctx);\n} sony2fuji_ai_denoise_config;",
            ),
        )
        for label, old, new in mutations:
            with tempfile.TemporaryDirectory(prefix=f"rawlab-abi-s2{label}-") as tmp:
                inc = Path(tmp) / "include"
                shutil.copytree(INCLUDE_DIR, inc)
                c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
                text = c_header.read_text(encoding="utf-8")
                mutated = text.replace(old, new, 1)
                self.assertTrue(text != mutated, f"Failed to apply {label} inline mutation")
                c_header.write_text(mutated, encoding="utf-8")

                result = self.regenerate(Path(tmp) / "abi-layout-v1.json", inc)
                self.assertNotEqual(result.returncode, 0, f"{label} inline function pointer accepted")
                self.assertIn(
                    "inline function pointer",
                    result.stderr,
                    f"{label} mutation missing gate error: {result.stderr}",
                )

    def test_formatting_comments_and_param_names_do_not_drift(self):
        self.assertEqual(self.baseline_result.returncode, 0)
        with tempfile.TemporaryDirectory(prefix="rawlab-abi-norm-") as tmp:
            inc = Path(tmp) / "include"
            shutil.copytree(INCLUDE_DIR, inc)
            c_header = inc / "sony2fuji/ffi/sony2fuji_c.h"
            text = c_header.read_text(encoding="utf-8")
            mutated = text.replace(
                "sony2fuji_status sony2fuji_x3f_default_mode(const char* input_path, sony2fuji_x3f_mode* mode);",
                "sony2fuji_status\n/* comment */\nsony2fuji_x3f_default_mode(\n    char const *   renamed_path /* inline */,\n    enum sony2fuji_x3f_mode *  renamed_mode\n);",
                1,
            ).replace(
                "sony2fuji_status sony2fuji_session_create(sony2fuji_session** out_session);",
                "sony2fuji_status sony2fuji_session_create(struct sony2fuji_session * * different_name);",
                1,
            ).replace(
                "typedef int32_t (*sony2fuji_cancel_callback)(void* context);",
                "typedef int32_t (*sony2fuji_cancel_callback)(void* const renamed_ctx /* comment */);",
                1,
            ).replace(
                "typedef int32_t (*sony2fuji_ai_progress_callback)(void* context, int32_t phase, uint64_t completed, uint64_t total);",
                "typedef int32_t (*sony2fuji_ai_progress_callback)(\n    void *   renamed_ctx /* c */, int32_t renamed_phase,\n    uint64_t renamed_completed, uint64_t renamed_total\n);",
                1,
            )
            self.assertTrue(text != mutated, "Failed to apply formatting mutation")
            c_header.write_text(mutated, encoding="utf-8")

            out_path = Path(tmp) / "abi-layout-v1.json"
            result = self.regenerate(out_path, inc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            regenerated_text = out_path.read_text(encoding="utf-8")

        self.assertEqual(self.baseline_text, regenerated_text)


if __name__ == "__main__":
    unittest.main()
