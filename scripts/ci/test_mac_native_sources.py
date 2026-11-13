"""Guard for the shared Mac harness source list (Shared/tests/mac-native-sources.sh).

Eleven full-source Mac harnesses compile every RawLabMac/Sources file plus the
Shared Swift layer with `swiftc`. They glob RawLabMac/Sources and the Shared
top level, so new files there are picked up automatically, but Shared/Native
has no glob in these scripts: when ab9be520 added Shared/Native/HDRPresentation
.swift and Shared/HDRDisplay.swift and 6f940269 added HDRCameraProfileAssetStore
to Shared/Native/HDRImage.swift, every harness that hardcoded its list went red
at once (Engine.swift, EditorView.swift and MacEditedPhotoPreviews.swift now
reference those types). The harnesses now source one shared list instead; this
test pins that mechanism so the drift costs one line, not eleven, and a final
enumeration over RawLabMac/tests/*.sh keeps any new full-source harness from
re-introducing the broken shape (ai-denoise.sh was the eleventh that the
original ten-name whitelist missed).
"""
from pathlib import Path
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIST = ROOT / "Shared/tests/mac-native-sources.sh"

# The full-source harnesses that were red on the HDR source drift. Every one of
# them must keep sourcing the shared list and compiling against the HDR header.
# (test_every_full_source_harness_covers_native_and_hdr_header enumerates the
# whole directory so a new script outside this list cannot hide the drift.)
HARNESSES = (
    "batch-import-presentation",
    "compact-controls-presentation",
    "geometry-render",
    "geometry-viewport",
    "mac-perspective-integration",
    "mac-straighten-preview",
    "photo-effects-presentation",
    "progressive-render",
    "single-preview-interaction",
    "update-ui",
    "ai-denoise",
)
# The three sources the breaking commits added; the shared list must resolve
# all of them so no harness can compile the app sources without them again.
DRIFT_SOURCES = (
    "Shared/Native/HDRPresentation.swift",
    "Shared/HDRDisplay.swift",
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
        # Shared/tests holds harness entry points that each script passes
        # explicitly; the shared list covers the product layer only.
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
        for name in HARNESSES:
            with self.subTest(harness=name):
                text = (ROOT / "RawLabMac/tests" / (name + ".sh")).read_text()
                self.assertIn('source "$ROOT/Shared/tests/mac-native-sources.sh"', text)
                self.assertIn('"${MAC_SHARED_SWIFT_SOURCES[@]}"', text)
                self.assertIn('"$MAC_NATIVE_BRIDGING_HEADER"', text)
                self.assertNotIn("ffi/sony2fuji_c.h", text,
                                 name + ": Shared/Native needs the HDR header superset")
                # Passing the top-level glob next to the shared array would
                # feed swiftc every Shared source twice.
                self.assertNotIn('"$ROOT"/Shared/*.swift', text,
                                 name + ": raw glob duplicates MAC_SHARED_SWIFT_SOURCES")

    def test_bridging_header_resolves_to_the_hdr_superset(self):
        header = resolved_bridging_header()
        self.assertEqual(header, ROOT / "lutools/include/sony2fuji/ffi/sony2fuji_hdr.h",
                         "MAC_NATIVE_BRIDGING_HEADER must stay on the HDR superset header")
        self.assertTrue(header.is_file(), "stale bridging header: %s" % header)

    def test_shared_list_paths_exist(self):
        for path in resolved_shared_sources():
            self.assertTrue(path.is_file(), "stale path in shared list: %s" % path)

    def test_every_full_source_harness_covers_native_and_hdr_header(self):
        # Whole-directory enumeration (the interception power, per the review:
        # the original ten-name whitelist let the eleventh same-root script
        # ai-denoise.sh slip through). Any harness that globs the full app
        # sources or the Shared top level compiles the Shared layer and so
        # must cover Shared/Native too, either by sourcing the shared list or
        # by an explicit Shared/Native glob (the RawLabMac/build.sh shape),
        # and must not bridge the flat sony2fuji_c.h that lacks the HDR ABI.
        candidates = []
        for script in sorted((ROOT / "RawLabMac/tests").glob("*.sh")):
            text = script.read_text()
            if ('find "$ROOT/RawLabMac/Sources"' in text
                    or '"$ROOT"/Shared/*.swift' in text):
                candidates.append(script.name)
                with self.subTest(harness=script.name):
                    self.assertTrue(
                        'Shared/tests/mac-native-sources.sh' in text
                        or 'Shared/Native' in text,
                        script.name + ": globs the Shared layer but never compiles Shared/Native; "
                        "source Shared/tests/mac-native-sources.sh")
                    self.assertNotIn("ffi/sony2fuji_c.h", text,
                                     script.name + ": Shared/Native needs the HDR header superset")
        self.assertIn("ai-denoise.sh", candidates,
                      "the enumeration predicate must keep covering ai-denoise.sh")
        self.assertGreaterEqual(len(candidates), 12,
                                "the enumeration stopped covering the known full-source harnesses")

    def test_subset_harness_shares_the_native_list_and_header(self):
        # mac-geometry-draft compiles a named Mac subset with its own Shared
        # list; at least the Shared/Native set and the HDR header must come
        # from the shared mechanism, not a duplicated hardcoded list.
        text = (ROOT / "RawLabMac/tests/mac-geometry-draft.sh").read_text()
        self.assertIn('source "$ROOT/Shared/tests/mac-native-sources.sh"', text)
        self.assertIn('"${MAC_NATIVE_SWIFT_SOURCES[@]}"', text)
        self.assertIn('"$MAC_NATIVE_BRIDGING_HEADER"', text)
        self.assertNotIn("ffi/sony2fuji_c.h", text)


if __name__ == "__main__":
    unittest.main()
