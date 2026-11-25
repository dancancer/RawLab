"""Android JNI C++ sources stay below 800 lines.

Large JNI files mixed protocol, focus and rendering bindings and drew merge conflicts between
otherwise independent changes (jni_camera.cpp reached 1,098 lines before it was split into
protocol and focus units). Split by responsibility instead of raising the limit.
"""
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "RawLabAndroid/app/src/main/cpp"
MAX_LINES = 800


def oversized(directory, limit=MAX_LINES):
    found = []
    for path in sorted(directory.rglob("*")):
        if path.suffix in {".c", ".cc", ".cpp", ".h", ".hpp"} and path.is_file():
            count = len(path.read_text(encoding="utf-8", errors="replace").splitlines())
            if count >= limit:
                label = path.relative_to(ROOT) if ROOT in path.parents else path
                found.append(f"{label}: {count} lines")
    return found


class AndroidCppFileSizeTests(unittest.TestCase):
    def test_android_jni_sources_stay_below_the_limit(self):
        self.assertTrue(any(SOURCES.glob("*.cpp")), f"no C++ sources found under {SOURCES}")
        self.assertEqual(oversized(SOURCES), [], f"split Android C++ files below {MAX_LINES} lines")

    def test_limit_counts_lines_of_every_cpp_and_header(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "small.cpp").write_text("x\n" * 799)
            (root / "large.h").write_text("x\n" * 800)
            (root / "notes.txt").write_text("x\n" * 5000)
            self.assertEqual([Path(entry.split(":")[0]).name for entry in oversized(root)], ["large.h"])


if __name__ == "__main__":
    unittest.main()
