"""Guard for the shared Mac harness source list (Shared/tests/mac-native-sources.sh)."""
from pathlib import Path
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIST = ROOT / "Shared/tests/mac-native-sources.sh"
COMPILE_LIB = ROOT / "RawLabMac/tests/lib/compile.sh"

# Every full-source Mac harness (including the 4 harnesses previously bypassing
# mac-native-sources.sh) must route through RawLabMac/tests/lib/compile.sh.
HARNESSES = (
    "ai-batch-native",
    "ai-denoise",
    "batch-import-presentation",
    "compact-controls-presentation",
    "geometry-render",
    "geometry-viewport",
    "mac-perspective-integration",
    "mac-straighten-preview",
    "mac-ui-smoke",
    "mac-viewing-model",
    "photo-effects-presentation",
    "progressive-render",
    "update-ui",
    "viewport-preview",
    "x3f-workflow",
)
# The shared native sources the breaking commits added (HDRDisplay moved into RawLabKit).
DRIFT_SOURCES = (
    "Shared/Native/HDRPresentation.swift",
    "Shared/Native/HDRImage.swift",
)


def resolved_shared_sources():
    result = subprocess.run(
        ["bash", "-c", 'source Shared/tests/mac-native-sources.sh '
         '&& printf "%s\\n" "${MAC_SHARED_SWIFT_SOURCES[@]}"'],
        cwd=ROOT, env={**os.environ, "ROOT": str(ROOT)},
        capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return sorted(Path(line) for line in result.stdout.splitlines() if line)


def resolved_bridging_header():
    result = subprocess.run(
        ["bash", "-c", 'source Shared/tests/mac-native-sources.sh '
         '&& printf "%s\\n" "$MAC_NATIVE_BRIDGING_HEADER"'],
        cwd=ROOT, env={**os.environ, "ROOT": str(ROOT)},
        capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return Path(result.stdout.strip())


class MacHarnessSourceListTests(unittest.TestCase):
    def test_shared_list_resolves_every_shared_swift_source(self):
        self.assertTrue(LIST.is_file(), "Shared harness source list is missing")
        resolved = resolved_shared_sources()
        on_disk = sorted(list((ROOT / "Shared").glob("*.swift"))
                         + list((ROOT / "Shared/Native").glob("*.swift")))
        self.assertEqual(resolved, on_disk,
                         "the shared list must cover Shared/ and Shared/Native/ exactly; "
                         "add new Shared/Native files to Shared/tests/mac-native-sources.sh")

    def test_shared_list_covers_the_hdr_drift_sources(self):
        resolved = {str(p.relative_to(ROOT)) for p in resolved_shared_sources()}
        for name in DRIFT_SOURCES:
            self.assertIn(name, resolved)

    def test_full_source_harnesses_use_the_shared_list_and_hdr_header(self):
        lib_text = COMPILE_LIB.read_text(encoding="utf-8")
        self.assertIn('source "$ROOT/Shared/tests/mac-native-sources.sh"', lib_text)
        self.assertIn('"${MAC_SHARED_SWIFT_SOURCES[@]}"', lib_text)
        self.assertIn('"$MAC_NATIVE_BRIDGING_HEADER"', lib_text)
        self.assertNotIn('"$ROOT"/Shared/*.swift', lib_text)

        for name in HARNESSES:
            with self.subTest(harness=name):
                text = (ROOT / "RawLabMac/tests" / (name + ".sh")).read_text(encoding="utf-8")
                self.assertIn('RawLabMac/tests/lib/compile.sh', text)
                self.assertTrue(
                    "rawlab_mac_full_app_sources" in text
                    or "rawlab_mac_compile_native full-app" in text,
                    f"{name}: must resolve full app sources via RawLabMac/tests/lib/compile.sh",
                )
                self.assertNotIn("ffi/sony2fuji_c.h", text,
                                 name + ": Shared/Native needs the HDR header superset")
                self.assertNotIn('"$ROOT"/Shared/*.swift', text,
                                 name + ": raw glob duplicates MAC_SHARED_SWIFT_SOURCES")
                self.assertNotIn('find "$ROOT/RawLabMac/Sources" -name \'*.swift\'', text,
                                 name + ": raw find duplicates rawlab_mac_full_app_sources")

    def test_bridging_header_resolves_to_the_hdr_superset(self):
        header = resolved_bridging_header()
        self.assertEqual(header, ROOT / "lutools/include/sony2fuji/ffi/sony2fuji_hdr.h",
                         "MAC_NATIVE_BRIDGING_HEADER must stay on the HDR superset header")
        self.assertTrue(header.is_file(), "stale bridging header: %s" % header)

    def test_shared_list_paths_exist(self):
        for path in resolved_shared_sources():
            self.assertTrue(path.is_file(), "stale path in shared list: %s" % path)

    def test_every_full_source_harness_covers_native_and_hdr_header(self):
        candidates = []
        for script in sorted((ROOT / "RawLabMac/tests").glob("*.sh")):
            text = script.read_text(encoding="utf-8")
            self.assertNotIn('find "$ROOT/RawLabMac/Sources" -name \'*.swift\'', text,
                             f"{script.name}: must use rawlab_mac_full_app_sources instead of raw find")
            self.assertNotIn('"$ROOT"/Shared/*.swift', text,
                             f"{script.name}: must not raw-glob Shared/*.swift")
            self.assertNotIn('"$ROOT"/Shared/Native/*.swift', text,
                             f"{script.name}: must not raw-glob Shared/Native/*.swift")
            if "rawlab_mac_full_app_sources" in text or "rawlab_mac_compile_native full-app" in text:
                candidates.append(script.name)
                with self.subTest(harness=script.name):
                    self.assertNotIn("ffi/sony2fuji_c.h", text,
                                     script.name + ": Shared/Native needs the HDR header superset")
        for expected in ("ai-denoise.sh", "ai-batch-native.sh", "mac-viewing-model.sh", "viewport-preview.sh", "x3f-workflow.sh"):
            self.assertIn(expected, candidates)
        self.assertGreaterEqual(len(candidates), len(HARNESSES))

    def test_subset_harness_shares_the_native_list_and_header(self):
        text = (ROOT / "RawLabMac/tests/mac-geometry-draft.sh").read_text(encoding="utf-8")
        self.assertIn('source "$ROOT/Shared/tests/mac-native-sources.sh"', text)
        self.assertIn('"${MAC_NATIVE_SWIFT_SOURCES[@]}"', text)
        self.assertIn('"$MAC_NATIVE_BRIDGING_HEADER"', text)
        self.assertNotIn("ffi/sony2fuji_c.h", text)


if __name__ == "__main__":
    unittest.main()
