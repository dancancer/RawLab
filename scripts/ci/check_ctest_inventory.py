#!/usr/bin/env python3
"""Verify CTest inventory, LABELS coverage, and test-source registration via `ctest --show-only=json-v1`."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
LUTOOLS_TESTS_DIR = ROOT / "lutools" / "tests"

REQUIRED_UNLESS_EXCLUDED: dict[str, set[str]] = {
    "ci_macos_arm64": {"hw_gpu", "ai_model", "directml"},
    "ci_macos_x86_64": {"hw_gpu", "ai_model", "directml", "metal_arm64", "arm64_only"},
    "ci_windows": {"hw_gpu", "external_raw", "gles_shader", "ai_model"},
}

FORBIDDEN_ON_CI: dict[str, set[str]] = {
    "ci_macos_arm64": {"directml"},
    "ci_macos_x86_64": {"directml", "metal_arm64", "arm64_only"},
    "ci_windows": {"hw_gpu", "external_raw", "gles_shader", "ai_model"},
}

# Test source filenames in lutools/tests/ mapped to target executable stem when they differ,
# or documented as non-CTest probes/benchmarks/helpers/platform-specific targets.
NON_CTEST_OR_HELPER_SOURCES: dict[str, str] = {
    "denoise_cache_benchmark.cpp": "manual_benchmark_exclude_from_all",
    "denoise_display_probe.cpp": "manual_probe_executable",
    "denoise_quality_probe.cpp": "invoked_by_denoise_quality_runner",
    "denoise_sharpen_probe.cpp": "manual_probe_executable",
    "atmosphere_quality_probe.cpp": "manual_probe_executable",
    "dualdn_probe.cpp": "manual_ai_package_probe",
    "geometry_benchmark.cpp": "manual_benchmark_exclude_from_all",
    "geometry_viewport_probe.cpp": "manual_probe_exclude_from_all",
    "gles_shader_source.cpp": "compiled_directly_by_check_gles_shader_py",
    "hdr_heif_fixture.mm": "apple_helper_for_hdr_portable_tests",
    "look_gamma_oracle.cpp": "helper_linked_into_look_exactness_tests",
    "look_lut_oracle.cpp": "helper_linked_into_look_exactness_tests",
    "nikon_he_reference_tests.cpp": "manual_external_nef_pgm_reference_probe",
    "photo_geometry_oracle.cpp": "helper_linked_into_photo_geometry_exactness_tests",
    "processing_export_probe.cpp": "manual_probe_exclude_from_all",
    "raw_decode_benchmark.cpp": "manual_benchmark_exclude_from_all",
    "render_benchmark.cpp": "manual_benchmark_exclude_from_all",
    "wavelet_legacy_memory_tests.cpp": "manual_62_9mp_memory_probe_exclude_from_all",
}

SOURCE_TO_EXECUTABLE_STEM: dict[str, str] = {
    "nikon_he_tests.cpp": "nikon_he_codec_tests",
    "raw_smoke.cpp": "raw_smoke",
    "highlight_regression.cpp": "highlight_regression",
}

APPLE_ONLY_TEST_SOURCES = {
    "display_image_tests.cpp",
    "hdr_image_tests.mm",
    "metal_lut_init_retry_tests.mm",
    "metal_workspace_tests.mm",
    "noise_aware_sharpen_metal_failure_tests.mm",
    "rendered_dng_imageio_tests.mm",
}
WINDOWS_ONLY_TEST_SOURCES = {
    "d3d11_shader_tests.cpp",
}
PORTABLE_HDR_ONLY_TEST_SOURCES = {
    "hdr_portable_tests.cpp",
}
LIBRAW_SOURCE_ONLY_TEST_SOURCES = {
    "sony_arw6_bounds_tests.cpp",
}
AI_DENOISE_ONLY_TEST_SOURCES = {
    "dualdn_directml_tests.cpp",
    "dualdn_native_tests.cpp",
    "dualdn_onnx_tests.cpp",
    "dualdn_session_tests.cpp",
}


def parse_cmake_cache(build_dir: Path) -> dict[str, str]:
    cache_path = build_dir / "CMakeCache.txt"
    if not cache_path.is_file():
        return {}
    values: dict[str, str] = {}
    for line in cache_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith(("#", "//")):
            continue
        if "=" not in line:
            continue
        key_type, val = line.split("=", 1)
        key = key_type.split(":", 1)[0]
        values[key] = val
    return values


def _cache_truthy(cache: dict[str, str], key: str) -> bool:
    return cache.get(key, "").upper() in {"ON", "TRUE", "1", "YES"}


def resolve_ctest_config(cache: dict[str, str], explicit_config: str | None = None) -> str | None:
    if explicit_config:
        return explicit_config
    if cache.get("CMAKE_BUILD_TYPE", "").strip():
        return None
    config_types = cache.get("CMAKE_CONFIGURATION_TYPES", "").strip()
    if not config_types:
        return None
    configs = [item.strip() for item in config_types.split(";") if item.strip()]
    if "Release" in configs:
        return "Release"
    return configs[0] if configs else None


def load_ctest_json(build_dir: Path, ctest_bin: str = "ctest", config: str | None = None) -> dict:
    if config is None:
        config = resolve_ctest_config(parse_cmake_cache(build_dir))
    cmd = [ctest_bin, "--test-dir", str(build_dir)]
    if config:
        cmd.extend(["-C", config])
    cmd.append("--show-only=json-v1")
    output = subprocess.check_output(
        cmd,
        text=True,
        encoding="utf-8",
    )
    return json.loads(output)


def test_labels(entry: dict) -> set[str]:
    for prop in entry.get("properties", []):
        if prop.get("name") == "LABELS":
            return set(prop.get("value") or [])
    return set()


def test_executable_stem(entry: dict) -> str | None:
    cmd = entry.get("command") or []
    if not cmd:
        return None
    return Path(cmd[0]).stem


def validate_ctest_inventory(
    data: dict,
    ci_label: str | None = None,
    platform: str | None = None,
    tests_dir: Path | None = None,
    ai_enabled: bool = False,
    portable_hdr_enabled: bool | None = None,
    libraw_source_present: bool | None = None,
) -> list[str]:
    errors: list[str] = []
    tests = data.get("tests")
    if not isinstance(tests, list) or not tests:
        return ["ctest --show-only=json-v1 returned no tests"]

    if ci_label is not None and ci_label not in REQUIRED_UNLESS_EXCLUDED:
        return [f"Unknown CI label: {ci_label}"]

    ci_count = 0
    observed_stems: set[str] = set()
    for entry in tests:
        name = entry.get("name", "<unnamed>")
        labels = test_labels(entry)
        if not labels:
            errors.append(f"Unlabeled CTest: {name}")
            continue
        stem = test_executable_stem(entry)
        if stem:
            observed_stems.add(stem)
        if ci_label is not None:
            has_ci = ci_label in labels
            if has_ci:
                ci_count += 1
            if not has_ci and not (labels & REQUIRED_UNLESS_EXCLUDED[ci_label]):
                errors.append(
                    f"CTest {name} is missing {ci_label} and has no exclusion label "
                    f"(labels={sorted(labels)})"
                )
            forbidden = labels & FORBIDDEN_ON_CI[ci_label]
            if has_ci and forbidden:
                errors.append(
                    f"CTest {name} carries forbidden label(s) {sorted(forbidden)} "
                    f"alongside {ci_label}"
                )

    if ci_label is not None and ci_count == 0:
        errors.append(f"Zero CTests carry CI label {ci_label}")

    if tests_dir is not None and observed_stems:
        if portable_hdr_enabled is None:
            portable_hdr_enabled = platform != "macos"
        if libraw_source_present is None:
            libraw_source_present = platform == "windows"
        on_disk = sorted(
            p.name
            for suffix in (".cpp", ".mm")
            for p in tests_dir.glob(f"*{suffix}")
        )
        for fname in on_disk:
            if fname in NON_CTEST_OR_HELPER_SOURCES:
                continue
            if platform == "macos" and fname in WINDOWS_ONLY_TEST_SOURCES:
                continue
            if platform == "windows" and fname in APPLE_ONLY_TEST_SOURCES:
                continue
            if not portable_hdr_enabled and fname in PORTABLE_HDR_ONLY_TEST_SOURCES:
                continue
            if not libraw_source_present and fname in LIBRAW_SOURCE_ONLY_TEST_SOURCES:
                continue
            if not ai_enabled and fname in AI_DENOISE_ONLY_TEST_SOURCES:
                continue
            expected_stem = SOURCE_TO_EXECUTABLE_STEM.get(fname, Path(fname).stem)
            if expected_stem not in observed_stems:
                errors.append(
                    f"Test source lutools/tests/{fname} (expected target {expected_stem}) "
                    f"has no active CTest command in ctest --show-only=json-v1"
                )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, help="Configured CMake build directory")
    parser.add_argument("--json", type=Path, help="Pre-captured ctest --show-only=json-v1 JSON file")
    parser.add_argument("--ci-label", choices=sorted(REQUIRED_UNLESS_EXCLUDED), help="CI label to verify")
    parser.add_argument("--platform", choices=("macos", "windows", "linux"), help="Host platform for source check")
    parser.add_argument("--ai-enabled", action="store_true", help="Expect SONY2FUJI_ENABLE_AI_DENOISE=ON test targets")
    parser.add_argument("--skip-orphan-check", action="store_true", help="Skip lutools/tests/*.{cpp,mm} source check")
    parser.add_argument("--ctest-bin", default="ctest", help="Path to ctest executable")
    parser.add_argument("--config", help="CMake configuration for multi-config generators (auto-detected if omitted)")
    args = parser.parse_args(argv)

    if bool(args.build_dir) == bool(args.json):
        parser.error("Specify exactly one of --build-dir or --json")

    cache: dict[str, str] = {}
    if args.json:
        data = json.loads(args.json.read_text(encoding="utf-8"))
    else:
        cache = parse_cmake_cache(args.build_dir)
        config = resolve_ctest_config(cache, args.config)
        data = load_ctest_json(args.build_dir, args.ctest_bin, config=config)

    ai_enabled = args.ai_enabled or _cache_truthy(cache, "SONY2FUJI_ENABLE_AI_DENOISE")
    portable_hdr = _cache_truthy(cache, "SONY2FUJI_TEST_PORTABLE_HDR") if "SONY2FUJI_TEST_PORTABLE_HDR" in cache else None
    libraw_src = cache.get("SONY2FUJI_TEST_LIBRAW_SOURCE", "")
    libraw_source_present = (Path(libraw_src) / "src/decoders/sony_arw6.cpp").is_file() if libraw_src else (False if cache else None)

    tests_dir = None if args.skip_orphan_check else LUTOOLS_TESTS_DIR
    errors = validate_ctest_inventory(
        data,
        ci_label=args.ci_label,
        platform=args.platform,
        tests_dir=tests_dir,
        ai_enabled=ai_enabled,
        portable_hdr_enabled=portable_hdr,
        libraw_source_present=libraw_source_present,
    )
    if errors:
        for err in errors:
            print(f"FAIL: {err}", file=sys.stderr)
        return 1

    tests = data["tests"]
    if args.ci_label:
        selected = sum(1 for t in tests if args.ci_label in test_labels(t))
        print(f"PASS: {len(tests)} CTest(s) verified ({selected} selected by -L ^{args.ci_label}$)")
    else:
        print(f"PASS: {len(tests)} CTest(s) verified with valid LABELS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
