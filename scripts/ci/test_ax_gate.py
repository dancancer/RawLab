"""Guard for the shared RAWLAB_REQUIRE_AX gate (RawLabMac/tests/ax-gate.sh).

The three accessibility-based Mac UI suites (hdr-rendition-ui, color-grading-input-ui,
system-menu-language) read UI state through AXUIElement. In a session without the
accessibility grant they cannot run any check at all: the rendition suite used to exit 0
after a bare skip (green but nothing ran), while the other two failed with unrelated
symptom messages ("wheel missing", empty menu titles) that hid the environment cause
(ledger B3/C). They now share one sourced gate that turns "no accessibility" into a
one-line SKIP exit 0, or into a one-line FAIL exit 1 when RAWLAB_REQUIRE_AX is set for
local/pre-release runs (docs/process/ci.md, Local and Targeted Entry Points). This test
pins the wiring statically so a new AX suite that forgets the gate, or a suite that
re-implements it ad hoc, costs one line here instead of a fresh green-but-did-not-run.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "RawLabMac/tests/ax-gate.sh"

# The AXUIElement-based manual suites named by the ledger (B3/C rows) and ci.md.
AX_SUITES = (
    "hdr-rendition-ui.sh",
    "color-grading-input-ui.sh",
    "system-menu-language.sh",
)

# The single reason line the gate prints when RAWLAB_REQUIRE_AX is set and AX is
# unavailable. HDRRenditionUITests.swift keeps the same wording as its second-layer
# guard (ci.md documents that contract), so the grep anchor for "failed with a reason"
# stays one string across all three entry points.
FAIL_REASON = ("RAWLAB_REQUIRE_AX is set but accessibility is not granted; "
               "the AX checks cannot run")


class AxGateTests(unittest.TestCase):
    def test_shared_gate_defines_require_ax_fail_and_skip(self):
        text = GATE.read_text(encoding="utf-8")
        self.assertIn("rawlab_ax_gate()", text)
        self.assertIn('RAWLAB_REQUIRE_AX:-', text)
        self.assertIn(FAIL_REASON, text)
        self.assertIn("SKIP:", text)

    def test_each_ax_suite_sources_and_calls_the_shared_gate(self):
        for name in AX_SUITES:
            with self.subTest(suite=name):
                text = (ROOT / "RawLabMac/tests" / name).read_text(encoding="utf-8")
                self.assertIn("RawLabMac/tests/ax-gate.sh", text,
                              f"{name} must source the shared AX gate")
                self.assertIn("\nrawlab_ax_gate\n", text,
                              f"{name} must call rawlab_ax_gate, which exits on its own")

    def test_rendition_guard_keeps_the_shared_fail_reason_wording(self):
        swift = (ROOT / "RawLabMac/tests/HDRRenditionUITests.swift").read_text(encoding="utf-8")
        self.assertIn(FAIL_REASON, swift,
                      "the second-layer Swift guard must keep the gate's one-line reason")


if __name__ == "__main__":
    unittest.main()
