"""Reconcile lutools/tests/*.cpp files against CMake add_executable registrations."""

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

# C++ files in lutools/tests/ that are compiled by Python/auxiliary scripts rather than CMake.
NON_CMAKE_TEST_HELPERS = {
    "gles_shader_source.cpp": "compiled_directly_by_check_gles_shader_py",
}


def _extract_cmake_registered_test_sources(cmake_files: list[Path]) -> set[str]:
    """Return test filenames (relative to lutools/tests/) referenced in CMake add_executable calls."""
    sources: set[str] = set()
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
            if not m_add:
                continue

            tokens: list[str] = []
            for tok in m_add.group(1).split():
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

            for tok_list in expanded:
                for tok in tok_list:
                    if tok.startswith("tests/") and tok.endswith(".cpp"):
                        sources.add(tok[len("tests/"):])

    return sources


class LutoolsTestInventoryTests(unittest.TestCase):
    def test_all_cpp_tests_are_registered_in_cmake(self) -> None:
        cmake_files = [LUTOOLS_DIR / "CMakeLists.txt"] + sorted((LUTOOLS_DIR / "cmake").rglob("*.cmake"))
        registered = _extract_cmake_registered_test_sources(cmake_files)
        on_disk = {p.name for p in LUTOOLS_TESTS_DIR.glob("*.cpp")}

        unregistered = sorted(on_disk - registered - set(NON_CMAKE_TEST_HELPERS.keys()))
        self.assertEqual(
            unregistered,
            [],
            f"Orphan C++ test file(s) in lutools/tests/ not registered in CMake: {unregistered}",
        )

        stale_helpers = sorted(set(NON_CMAKE_TEST_HELPERS.keys()) - on_disk)
        self.assertEqual(stale_helpers, [], f"Stale NON_CMAKE_TEST_HELPERS entries: {stale_helpers}")

        registered_helpers = sorted(set(NON_CMAKE_TEST_HELPERS.keys()) & registered)
        self.assertEqual(
            registered_helpers,
            [],
            f"Helper(s) listed in NON_CMAKE_TEST_HELPERS are now registered in CMake: {registered_helpers}",
        )


if __name__ == "__main__":
    unittest.main()
