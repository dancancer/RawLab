"""Source contracts complement the native white-balance/vignette acceptance."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ToolGroupUIContracts(unittest.TestCase):
    def test_dock_exposes_one_white_balance_entry(self):
        source = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentDock.swift").read_text()
        self.assertNotIn("[AdjustmentParameter.temperature, .tint,", source)
        self.assertIn('parameter.isWhiteBalance ? L10n.text("白平衡") : spec.title', source)
        self.assertIn("selected.isWhiteBalance ? AdjustmentParameter.temperature.rawValue", source)

    def test_white_balance_context_reset_resets_both_parameters(self):
        source = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentDock.swift").read_text()
        self.assertIn("if parameter.isWhiteBalance { model.settings.resetWhiteBalance() }", source)
        self.assertIn("!model.settings.isWhiteBalanceDefault", source)

    def test_collapsed_vignette_hides_both_reset_controls(self):
        source = (ROOT / "RawLabMac/Sources/Controls/PhotoEffectsControls.swift").read_text()
        self.assertIn("if !isVignette || advanced { Button", source)
        self.assertIn("showsReset: !isVignette || advanced", source)
        row = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentRow.swift").read_text()
        self.assertIn("var showsReset = true", row)
        self.assertIn("if showsReset { Button", row)

    def test_group_reset_has_a_distinct_accessibility_identifier(self):
        source = (ROOT / "RawLabMac/Sources/Controls/PhotoEffectsControls.swift").read_text()
        self.assertIn('accessibilityIdentifier("effects.resetGroup.', source)


if __name__ == "__main__":
    unittest.main()
