"""CI mutation anchors verifying critical contract gates fail red when invariants are broken."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def _copy_files(dst_root: Path, rel_paths: tuple[str, ...] | list[str]) -> None:
    for rel in rel_paths:
        src = ROOT / rel
        dst = dst_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def _git_init_and_commit(repo: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "mutation-test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Mutation Test"], cwd=repo, check=True)
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "sandbox baseline"], cwd=repo, check=True)


def _run_test_script(target: Path, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(target)],
        capture_output=True,
        text=True,
        cwd=cwd,
    )


class MutationAnchorTests(unittest.TestCase):
    def test_anchor_1_version_drift_fails_version_check(self) -> None:
        files = (
            "scripts/version/generate.py",
            "Shared/version.json",
            "RawLab/RawLab/Resources/Info.plist",
            "RawLabMac/Info.plist",
            "RawLabAndroid/app/build.gradle.kts",
            "RawLabWindows/RawLabWindows.csproj",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-version-") as tmp:
            root = Path(tmp)
            _copy_files(root, files)
            cmd = [sys.executable, str(root / "scripts/version/generate.py"), "--check", "--root", str(root)]
            baseline = subprocess.run(cmd, capture_output=True, text=True, cwd=root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            version_file = root / "Shared/version.json"
            data = json.loads(version_file.read_text(encoding="utf-8"))
            data["version"] = "99.0.0"
            version_file.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

            mutated = subprocess.run(cmd, capture_output=True, text=True, cwd=root)
            self.assertNotEqual(mutated.returncode, 0, "Version drift must fail version generate.py --check")

    def test_anchor_2_spec_range_drift_without_regen_fails_specs_check(self) -> None:
        files = (
            "scripts/specs/generate.py",
            "Shared/specs/adjustment-fields-v1.json",
            "Shared/RawLabKit/AdjustmentFieldSpec.generated.swift",
            "RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentFieldSpec.kt",
            "RawLabWindows/Core/AdjustmentFieldSpec.g.cs",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-specs-") as tmp:
            root = Path(tmp)
            _copy_files(root, files)
            cmd = [sys.executable, str(root / "scripts/specs/generate.py"), "--check", "--root", str(root)]
            baseline = subprocess.run(cmd, capture_output=True, text=True, cwd=root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            spec_file = root / "Shared/specs/adjustment-fields-v1.json"
            doc = json.loads(spec_file.read_text(encoding="utf-8"))
            exposure = next(f for f in doc["fields"] if f["field_id"] == "light.exposure")
            exposure["protocol"]["max"] = 15.0
            spec_file.write_text(json.dumps(doc), encoding="utf-8")

            mutated = subprocess.run(cmd, capture_output=True, text=True, cwd=root)
            self.assertNotEqual(mutated.returncode, 0, "Unregenerated spec drift must fail specs generate.py --check")

    def test_anchor_3_unclassified_fallback_all_platforms_fails_affected_platforms(self) -> None:
        files = (
            "scripts/ci/affected_platforms.py",
            "scripts/ci/test_affected_platforms.py",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-affected-") as tmp:
            root = Path(tmp)
            _copy_files(root, files)
            # Satisfy git grep check in ClassificationTests with a valid shared Mac fixture reference.
            ref_file = root / "RawLab/ref.txt"
            ref_file.parent.mkdir(parents=True, exist_ok=True)
            ref_file.write_text("RawLabMac/tests/DCPTestFixtures.swift\n", encoding="utf-8")
            _git_init_and_commit(root)

            test_target = root / "scripts/ci/test_affected_platforms.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            ap_file = root / "scripts/ci/affected_platforms.py"
            source = ap_file.read_text(encoding="utf-8")
            old_tail = (
                "    if path in SHARED_FILES or path.startswith(SHARED_PREFIXES):\n"
                "        return set(PLATFORMS)\n"
                "    return set()\n"
            )
            new_tail = (
                "    if path in SHARED_FILES or path.startswith(SHARED_PREFIXES):\n"
                "        return set(PLATFORMS)\n"
                "    return set(PLATFORMS)\n"
            )
            self.assertEqual(source.count(old_tail), 1)
            ap_file.write_text(source.replace(old_tail, new_tail, 1), encoding="utf-8")

            mutated = _run_test_script(test_target, root)
            self.assertNotEqual(mutated.returncode, 0, "Fallback to all platforms must fail test_affected_platforms.py")
            self.assertIn(
                "test_documentation_bookkeeping_and_unclassified_select_no_platform",
                mutated.stdout + mutated.stderr,
            )

    def test_anchor_4_dead_doc_link_fails_test_doc_links(self) -> None:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-doclinks-") as tmp:
            root = Path(tmp)
            _copy_files(root, ("scripts/ci/test_doc_links.py",))
            for raw_entry in tracked:
                if not raw_entry:
                    continue
                rel = raw_entry.decode("utf-8", errors="surrogateescape")
                src = ROOT / rel
                dst = root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                if rel.endswith(".md") and not rel.startswith(("docs/archive/", ".impeccable/", "lutools/x3f-bridge/vendor/")):
                    shutil.copy2(src, dst)
                elif src.is_dir():
                    dst.mkdir(parents=True, exist_ok=True)
                else:
                    # Touch lightweight placeholders so every real relative target in active docs exists.
                    dst.touch()
            _git_init_and_commit(root)

            test_target = root / "scripts/ci/test_doc_links.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            active_doc = root / "PRODUCT.md"
            active_doc.write_text(
                active_doc.read_text(encoding="utf-8") + "\n[Injected dead link](does/not/exist.md)\n",
                encoding="utf-8",
            )

            mutated = _run_test_script(test_target, root)
            self.assertNotEqual(mutated.returncode, 0, "Injected dead link must fail test_doc_links.py")
            self.assertIn("does/not/exist.md", mutated.stdout + mutated.stderr)

    def test_anchor_5_assets_make_latest_true_fails_test_assets_prepare(self) -> None:
        files = (
            "scripts/assets/prepare.py",
            "scripts/ci/test_assets_prepare.py",
            "Shared/assets-manifest.json",
            "Shared/BundledLooks/catalog.json",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-assets-") as tmp:
            root = Path(tmp)
            _copy_files(root, files)
            test_target = root / "scripts/ci/test_assets_prepare.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            manifest_file = root / "Shared/assets-manifest.json"
            manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
            manifest["releasePolicy"]["makeLatest"] = True
            manifest_file.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            mutated = _run_test_script(test_target, root)
            self.assertNotEqual(mutated.returncode, 0, "makeLatest=true must fail test_assets_prepare.py")
            self.assertIn("makeLatest", mutated.stdout + mutated.stderr)

    def test_anchor_6_cli_private_include_fails_test_cli_layering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-cli-") as tmp:
            root = Path(tmp)
            _copy_files(root, ("scripts/ci/test_cli_layering.py",))
            shutil.copytree(ROOT / "lutools/src/cli", root / "lutools/src/cli")

            test_target = root / "scripts/ci/test_cli_layering.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            agent_cpp = root / "lutools/src/cli/agent_commands.cpp"
            agent_cpp.write_text(
                '#include "core/pipeline.h"\n' + agent_cpp.read_text(encoding="utf-8"),
                encoding="utf-8",
            )

            mutated = _run_test_script(test_target, root)
            self.assertNotEqual(mutated.returncode, 0, "Injected CLI private include must fail test_cli_layering.py")
            self.assertIn("core/pipeline.h", mutated.stdout + mutated.stderr)

    def test_anchor_7_parallel_skip_swallow_fails_test_apple_models(self) -> None:
        files = (
            "scripts/ci/apple-models.sh",
            "scripts/ci/swiftpm-rawlabkit.sh",
            "scripts/ci/test_apple_models.py",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-apple-skip-") as tmp:
            root = Path(tmp)
            _copy_files(root, files)
            test_target = root / "scripts/ci/test_apple_models.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            runner = root / "scripts/ci/apple-models.sh"
            source = runner.read_text(encoding="utf-8")
            old_block = (
                '                if ! fail_on_logged_skip "$suite_log" "$suite"; then\n'
                '                    skip_fail=1\n'
                '                fi\n'
            )
            self.assertEqual(source.count(old_block), 1)
            runner.write_text(source.replace(old_block, "", 1), encoding="utf-8")

            mutated = _run_test_script(test_target, root)
            self.assertNotEqual(mutated.returncode, 0, "Dropping parallel SKIP check must fail test_apple_models.py")
            self.assertIn("test_parallel_logged_skip_in_any_concurrent_worker_fails_without_swallowing", mutated.stdout + mutated.stderr)

    def test_anchor_8_native_cache_decoupling_revert_to_red(self) -> None:
        patterns = (
            "scripts/ci/native_cache.py",
            "scripts/ci/test_native_cache.py",
            "scripts/ci/affected_platforms.py",
            "scripts/ci/requirements.txt",
            ".github/workflows/ci.yml",
            "lutools/CMakeLists.txt",
            "lutools/cmake/**/*.cmake",
            "lutools/cmake/**/CMakeLists.txt",
            "lutools/cmake/**/*.py",
            "lutools/cmake/**/*.json",
            "lutools/cmake/**/*.in",
            "lutools/cmake/**/*.inc",
            "lutools/third_party/rawspeed-camera-calibration.inc",
            "lutools/third_party/lensfun/*.*",
            "lutools/third_party/nikon_he/*",
            "lutools/third_party/libraw/*",
            "RawLabMac/build*.sh",
            "RawLabWindows/build.ps1",
            "RawLabWindows/native/CMakeLists.txt",
            "RawLabAndroid/app/src/main/cpp/CMakeLists.txt",
            "RawLabAndroid/*.gradle.kts",
            "RawLabAndroid/app/build.gradle.kts",
            "RawLabAndroid/gradle.properties",
            "RawLabAndroid/gradle/wrapper/gradle-wrapper.properties",
            "lutools/platform/ios/build-framework.sh",
        )
        with tempfile.TemporaryDirectory(prefix="rawlab-mut-native-cache-") as tmp:
            root = Path(tmp)
            rel_files = []
            for pattern in patterns:
                for src in ROOT.glob(pattern):
                    if src.is_file():
                        rel_files.append(src.relative_to(ROOT).as_posix())
            _copy_files(root, sorted(set(rel_files)))

            test_target = root / "scripts/ci/test_native_cache.py"
            baseline = _run_test_script(test_target, root)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            # Mutation A: re-coupling lutools/CMakeLists.txt into COMMON_INPUTS must fail RED.
            nc_file = root / "scripts/ci/native_cache.py"
            nc_orig = nc_file.read_text(encoding="utf-8")
            old_line = '    "scripts/ci/native_cache.py", "scripts/ci/requirements.txt",'
            new_line = '    "scripts/ci/native_cache.py", "scripts/ci/requirements.txt", "lutools/CMakeLists.txt",'
            self.assertEqual(nc_orig.count(old_line), 1)
            nc_file.write_text(nc_orig.replace(old_line, new_line, 1), encoding="utf-8")
            mutated_a = _run_test_script(test_target, root)
            self.assertNotEqual(mutated_a.returncode, 0, "Re-adding lutools/CMakeLists.txt to COMMON_INPUTS must fail RED")
            self.assertIn("test_first_party_cmakelists_edits_preserve_cache_key_across_all_platforms", mutated_a.stdout + mutated_a.stderr)
            nc_file.write_text(nc_orig, encoding="utf-8")

            # Mutation B: dropping lutools/cmake/**/*.cmake from COMMON_INPUTS must fail RED.
            old_cmake_glob = '    "lutools/cmake/**/*.cmake", "lutools/cmake/**/CMakeLists.txt",'
            new_cmake_glob = '    "lutools/cmake/**/CMakeLists.txt",'
            self.assertEqual(nc_orig.count(old_cmake_glob), 1)
            nc_file.write_text(nc_orig.replace(old_cmake_glob, new_cmake_glob, 1), encoding="utf-8")
            mutated_b = _run_test_script(test_target, root)
            self.assertNotEqual(mutated_b.returncode, 0, "Dropping lutools/cmake/**/*.cmake must fail RED")
            self.assertIn("test_third_party_cmake_edits_invalidate_cache_key_across_all_platforms", mutated_b.stdout + mutated_b.stderr)
            nc_file.write_text(nc_orig, encoding="utf-8")

            # Mutation C: injecting third-party FetchContent/pkg_check_modules into lutools/CMakeLists.txt must fail RED.
            cm_file = root / "lutools/CMakeLists.txt"
            cm_orig = cm_file.read_text(encoding="utf-8")
            cm_file.write_text(cm_orig + "\npkg_check_modules(BAD REQUIRED libbad)\n", encoding="utf-8")
            mutated_c = _run_test_script(test_target, root)
            self.assertNotEqual(mutated_c.returncode, 0, "Injecting third-party lookup into lutools/CMakeLists.txt must fail RED")
            self.assertIn("test_lutools_cmakelists_delegates_third_party_deps_to_cmake_dir", mutated_c.stdout + mutated_c.stderr)


if __name__ == "__main__":
    unittest.main()
