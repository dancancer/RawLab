"""Guard for the shared RAWLAB_REQUIRE_AX gate (RawLabMac/tests/ax-gate.sh).

The three accessibility-based Mac UI suites (hdr-rendition-ui, color-grading-input-ui,
system-menu-language) read UI state through AXUIElement. In a session without the
accessibility grant they cannot run any check at all: the rendition suite used to exit 0
after a bare skip (green but nothing ran), while the other two failed with unrelated
symptom messages ("wheel missing", empty menu titles) that hid the environment cause
(ledger B3/C). They now share one sourced gate that turns "no accessibility" into a
one-line SKIP exit 0, or into a one-line FAIL exit 1 when RAWLAB_REQUIRE_AX is set for
local/pre-release runs (docs/process/ci.md, Local and Targeted Entry Points). The iOS
reset-entry suite (ledger D, Q14) is a mixed suite instead: its 30 presentation-layer
model assertions never depended on AX and must keep running in CI, so it has no
whole-script shell gate; only its two `if axTrusted` branches sit behind a Swift
second-layer guard that reuses the gate's exact wording (the form
HDRRenditionUITests.swift pioneered, and the only SKIP that apple-models.sh's
invariant-7 allow-list lets through). These pins keep a new AX suite from wiring
either form wrong instead of shipping a fresh green-but-did-not-run.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "RawLabMac/tests/ax-gate.sh"

# The shell-gated AXUIElement-based manual suites named by the ledger (B3/C rows) and
# ci.md, as paths relative to the repo root.
AX_SUITES = (
    "RawLabMac/tests/hdr-rendition-ui.sh",
    "RawLabMac/tests/color-grading-input-ui.sh",
    "RawLabMac/tests/system-menu-language.sh",
)

# The single reason line the gate prints when RAWLAB_REQUIRE_AX is set and AX is
# unavailable. HDRRenditionUITests.swift and IOSResetEntryUITests.swift keep the same
# wording as their second-layer guards (ci.md documents that contract), so the grep
# anchor for "failed with a reason" stays one string across all entry points.
FAIL_REASON = ("RAWLAB_REQUIRE_AX is set but accessibility is not granted; "
               "the AX checks cannot run")

# The gate's honest-skip notice, word for word. apple-models.sh invariant 7
# allow-lists this line (plus its ::warning:: twin) for the mixed iOS model suite.
SKIP_NOTICE = "SKIP: accessibility is not trusted here; the AX checks did not run"


class AxGateTests(unittest.TestCase):
    def test_shared_gate_defines_require_ax_fail_and_skip(self):
        text = GATE.read_text(encoding="utf-8")
        self.assertIn("rawlab_ax_gate()", text)
        self.assertIn('RAWLAB_REQUIRE_AX:-', text)
        self.assertIn(FAIL_REASON, text)
        self.assertIn("SKIP:", text)

    def test_each_ax_suite_sources_and_calls_the_shared_gate(self):
        for rel in AX_SUITES:
            with self.subTest(suite=rel):
                text = (ROOT / rel).read_text(encoding="utf-8")
                self.assertIn("RawLabMac/tests/ax-gate.sh", text,
                              f"{rel} must source the shared AX gate")
                self.assertIn("\nrawlab_ax_gate\n", text,
                              f"{rel} must call rawlab_ax_gate, which exits on its own")

    def test_rendition_guard_keeps_the_shared_fail_reason_wording(self):
        swift = (ROOT / "RawLabMac/tests/HDRRenditionUITests.swift").read_text(encoding="utf-8")
        self.assertIn(FAIL_REASON, swift,
                      "the second-layer Swift guard must keep the gate's one-line reason")

    def test_ios_mixed_suite_runs_models_unconditionally_with_the_gate_as_second_layer(self):
        # B2/Q14 pin: the shell entry must not gate the whole script (a pre-compile
        # rawlab_ax_gate skipped all 30 AX-free model checks along with the AX pair).
        shell = (ROOT / "RawLab/tests/ios-reset-entry-ui.sh").read_text(encoding="utf-8")
        self.assertNotIn("rawlab_ax_gate", shell,
                         "the mixed suite must compile and run its model checks unconditionally")
        swift = (ROOT / "RawLab/tests/IOSResetEntryUITests.swift").read_text(encoding="utf-8")
        self.assertIn("AXIsProcessTrusted()", swift,
                      "the guard must read the same in-process API the gate probes")
        self.assertIn('environment["RAWLAB_REQUIRE_AX"]', swift,
                      "the FAIL state must key on RAWLAB_REQUIRE_AX")
        self.assertIn(FAIL_REASON, swift,
                      "the iOS second-layer guard must keep the gate's one-line reason")
        self.assertIn(f'"{SKIP_NOTICE}"', swift,
                      "the iOS honest-skip line must match the gate and the models allow-list")
        self.assertIn('"::warning::" + notice', swift,
                      "the skip must keep the ::warning:: twin apple-models.sh matches on")
        self.assertLess(swift.rindex('print("PASS: '), swift.index(SKIP_NOTICE),
                        "the model assertions must run before the trailing AX skip is logged")


if __name__ == "__main__":
    unittest.main()
