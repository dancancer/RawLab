#!/usr/bin/env python3
"""Pinned extracted sources must remain identical to their verified archive."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hdr_sources", Path(__file__).parents[1] / "cmake/hdr_sources.py")
hdr_sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hdr_sources)


class SourceCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rawlab-hdr-source-test-")
        self.addCleanup(self.temporary.cleanup)
        self.cache = Path(self.temporary.name)
        directory = self.cache / "hdr-codecs"
        directory.mkdir()
        self.archive = directory / "test.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, content in {"CMakeLists.txt": b"project(codec)", "LICENSE": b"test license", "src/codec.cpp": b"original"}.items():
                member = tarfile.TarInfo("codec/" + name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        self.pin = {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(), "license_files": ["LICENSE"]}

    def prepare(self):
        return hdr_sources.prepare_source(self.cache, self.pin, "test.tar.gz", "codec")

    def test_reuses_identical_source(self):
        first = self.prepare()
        self.assertEqual(first, self.prepare())
        self.assertEqual(b"original", (first / "src/codec.cpp").read_bytes())

    def test_rejects_changed_source_without_overwriting_it(self):
        file = self.prepare() / "src/codec.cpp"
        file.write_bytes(b"modified")
        with self.assertRaisesRegex(RuntimeError, "Extracted dependency"):
            self.prepare()
        self.assertEqual(b"modified", file.read_bytes())

    def test_rejects_missing_license(self):
        (self.prepare() / "LICENSE").unlink()
        with self.assertRaisesRegex(RuntimeError, "Extracted dependency"):
            self.prepare()

    def test_rejects_added_source(self):
        (self.prepare() / "extra.cpp").write_text("untracked code")
        with self.assertRaisesRegex(RuntimeError, "Extracted dependency"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
