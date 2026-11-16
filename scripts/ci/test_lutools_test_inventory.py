"""Reconcile lutools/tests/*.{cpp,mm} files against CMake add_executable and add_test registrations."""

from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_windows_inventory import _strip_cmake_comments


ROOT = Path(__file__).resolve().parents[2]
LUTOOLS_DIR = ROOT / "lutools"
LUTOOLS_TESTS_DIR = LUTOOLS_DIR / "tests"
TEST_SOURCE_SUFFIXES = (".cpp", ".mm")

# Source files in lutools/tests/ that are compiled by Python/auxiliary scripts rather than CMake.
NON_CMAKE_TEST_HELPERS = {
    "gles_shader_source.cpp": "compiled_directly_by_check_gles_shader_py",
}

# CMake *_tests executable targets that are intentionally not bound to add_test()
# (e.g. manual probes, external-fixture reference tools, or EXCLUDE_FROM_ALL targets).
NON_CTEST_TEST_TARGETS = {
    "gpu_filter_tests": "android_exclude_from_all_manual_denoise_target",
    "nikon_he_reference_tests": "manual_external_nef_pgm_reference_probe",
    "wavelet_legacy_memory_tests": "manual_62_9mp_memory_probe_excluded_from_ctest",
}


def _expand_cmake_tokens(
    raw_tokens: list[str],
    variables: dict[str, list[str]],
    loop_stack: list[tuple[str, list[str]]],
) -> list[list[str]]:
    tokens: list[str] = []
    for tok in raw_tokens:
        m_var = re.fullmatch(r"\$\{([A-Za-z0-9_]+)\}", tok)
        if m_var and m_var.group(1) in variables:
            tokens.extend(variables[m_var.group(1)])
        else:
            tokens.append(tok)

    expanded = [tokens]
    for var, items in loop_stack:
        if not items:
            continue
        next_expanded: list[list[str]] = []
        placeholder = f"${{{var}}}"
        for tok_list in expanded:
            if any(placeholder in t for t in tok_list):
                for item in items:
                    next_expanded.append([t.replace(placeholder, item) for t in tok_list])
            else:
                next_expanded.append(tok_list)
        expanded = next_expanded
    return expanded


def _extract_cmake_test_inventory(cmake_files: list[Path]) -> tuple[set[str], set[str], set[str]]:
    """Return (test_sources, test_exec_targets, ctest_commands) from CMake files."""
    sources: set[str] = set()
    test_exec_targets: set[str] = set()
    ctest_commands: set[str] = set()
    variables: dict[str, list[str]] = {}

    for path in cmake_files:
        lines = _strip_cmake_comments(path.read_text(encoding="utf-8"))
        loop_stack: list[tuple[str, list[str]]] = []

        for line in lines:
            m_set = re.match(r"^set\s*\(\s*([A-Za-z0-9_]+)\s+(.+)\)$", line)
            if m_set:
                var = m_set.group(1)
                tokens = [t for t in m_set.group(2).split() if t not in {"CACHE", "INTERNAL", "PARENT_SCOPE"}]
                variables[var] = tokens
                continue

            m_for_items = re.match(r"^foreach\s*\(\s*([A-Za-z0-9_]+)\s+IN\s+ITEMS\s+(.+)\)$", line)
            if m_for_items:
                loop_stack.append((m_for_items.group(1), m_for_items.group(2).split()))
                continue

            m_for_lists = re.match(r"^foreach\s*\(\s*([A-Za-z0-9_]+)\s+IN\s+LISTS\s+(.+)\)$", line)
            if m_for_lists:
                items: list[str] = []
                for list_var in m_for_lists.group(2).split():
                    items.extend(variables.get(list_var, []))
                loop_stack.append((m_for_lists.group(1), items))
                continue

            m_for = re.match(r"^foreach\s*\(\s*([A-Za-z0-9_]+)\s+(.+)\)$", line)
            if m_for:
                var = m_for.group(1)
                items = m_for.group(2).split()
                if items and items[0] == "RANGE":
                    loop_stack.append((var, []))
                else:
                    loop_stack.append((var, items))
                continue

            if re.match(r"^endforeach\s*\(", line):
                if loop_stack:
                    loop_stack.pop()
                continue

            m_add = re.match(r"^add_executable\s*\((.+)\)$", line)
            if m_add:
                for tok_list in _expand_cmake_tokens(m_add.group(1).split(), variables, loop_stack):
                    if tok_list and tok_list[0].endswith("_tests"):
                        test_exec_targets.add(tok_list[0])
                    for tok in tok_list:
                        if tok.startswith("tests/") and tok.endswith(TEST_SOURCE_SUFFIXES):
                            sources.add(tok[len("tests/"):])
                continue

            m_target_sources = re.match(r"^target_sources\s*\((.+)\)$", line)
            if m_target_sources:
                for tok_list in _expand_cmake_tokens(m_target_sources.group(1).split(), variables, loop_stack):
                    for tok in tok_list:
                        if tok.startswith("tests/") and tok.endswith(TEST_SOURCE_SUFFIXES):
                            sources.add(tok[len("tests/"):])
                continue

            m_test = re.match(r"^add_test\s*\((.+)\)$", line)
            if m_test:
                for tok_list in _expand_cmake_tokens(m_test.group(1).split(), variables, loop_stack):
                    if "COMMAND" in tok_list:
                        cmd_idx = tok_list.index("COMMAND") + 1
                        if cmd_idx < len(tok_list):
                            ctest_commands.add(tok_list[cmd_idx].strip('"'))
                    for tok in tok_list:
                        m_tf = re.search(r"\$<TARGET_FILE:([^>]+)>", tok)
                        if m_tf:
                            ctest_commands.add(m_tf.group(1))

    return sources, test_exec_targets, ctest_commands


def _extract_cmake_registered_test_sources(cmake_files: list[Path]) -> set[str]:
    """Return test filenames (relative to lutools/tests/) referenced in CMake."""
    sources, _, _ = _extract_cmake_test_inventory(cmake_files)
    return sources


class LutoolsTestInventoryTests(unittest.TestCase):
    def test_all_cpp_and_mm_tests_are_registered_in_cmake(self) -> None:
        cmake_files = [LUTOOLS_DIR / "CMakeLists.txt"] + sorted((LUTOOLS_DIR / "cmake").rglob("*.cmake"))
        registered, _, _ = _extract_cmake_test_inventory(cmake_files)
        on_disk = {p.name for suffix in TEST_SOURCE_SUFFIXES for p in LUTOOLS_TESTS_DIR.glob(f"*{suffix}")}

        unregistered = sorted(on_disk - registered - set(NON_CMAKE_TEST_HELPERS.keys()))
        self.assertEqual(
            unregistered,
            [],
            f"Orphan C++/ObjC++ test file(s) in lutools/tests/ not registered in CMake: {unregistered}",
        )

        stale_helpers = sorted(set(NON_CMAKE_TEST_HELPERS.keys()) - on_disk)
        self.assertEqual(stale_helpers, [], f"Stale NON_CMAKE_TEST_HELPERS entries: {stale_helpers}")

        registered_helpers = sorted(set(NON_CMAKE_TEST_HELPERS.keys()) & registered)
        self.assertEqual(
            registered_helpers,
            [],
            f"Helper(s) listed in NON_CMAKE_TEST_HELPERS are now registered in CMake: {registered_helpers}",
        )

    def test_all_cmake_test_executables_have_add_test(self) -> None:
        cmake_files = [LUTOOLS_DIR / "CMakeLists.txt"] + sorted((LUTOOLS_DIR / "cmake").rglob("*.cmake"))
        _, test_exec_targets, ctest_commands = _extract_cmake_test_inventory(cmake_files)

        missing_ctest = sorted(test_exec_targets - ctest_commands - set(NON_CTEST_TEST_TARGETS.keys()))
        self.assertEqual(
            missing_ctest,
            [],
            f"CMake *_tests executable target(s) missing add_test(...) binding: {missing_ctest}",
        )

        stale_non_ctest = sorted(set(NON_CTEST_TEST_TARGETS.keys()) - test_exec_targets)
        self.assertEqual(stale_non_ctest, [], f"Stale NON_CTEST_TEST_TARGETS entries: {stale_non_ctest}")

        registered_non_ctest = sorted(set(NON_CTEST_TEST_TARGETS.keys()) & ctest_commands)
        self.assertEqual(
            registered_non_ctest,
            [],
            f"Target(s) listed in NON_CTEST_TEST_TARGETS now have add_test(...): {registered_non_ctest}",
        )


if __name__ == "__main__":
    unittest.main()
