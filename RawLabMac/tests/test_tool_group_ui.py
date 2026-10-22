"""Source contracts complement the native white-balance/vignette acceptance."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ToolGroupUIContracts(unittest.TestCase):
    def test_dock_exposes_one_white_balance_entry(self):
        source = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentDock.swift").read_text()
        self.assertIn("ForEach(group.tools)", source)
        descriptors = (ROOT / "RawLabMac/Sources/Adjustments/AdjustmentTypes.swift").read_text()
        self.assertIn("case .color: return [.whiteBalance, .saturation, .hsl]", descriptors)

    def test_white_balance_context_reset_uses_transaction(self):
        source = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentDock.swift").read_text()
        self.assertIn("model.requestAdjustmentReset(.tool(tool))", source)
        self.assertIn("model.isAdjustmentModified(.tool(tool))", source)
        self.assertNotIn("model.settings.resetEffect", source)
        behavior = (ROOT / "RawLabMac/tests/ControlGroupTests.swift").read_text()
        self.assertIn("Current WB reset restores mode and both camera parameters while preserving color peers", behavior)

    def test_collapsed_vignette_hides_group_reset_and_rows_use_semantic_reset(self):
        source = (ROOT / "RawLabMac/Sources/Controls/PhotoEffectsControls.swift").read_text()
        self.assertIn("if !isVignette || advanced { Button", source)
        self.assertNotIn("showsReset", source)
        row = (ROOT / "RawLabMac/Sources/Editor/View/AdjustmentRow.swift").read_text()
        self.assertNotIn("showsReset", row)
        self.assertNotIn('Image(systemName: "arrow.counterclockwise")', row)
        self.assertEqual(row.count(".modifier(ParameterResetGesture(action: reset))"), 2)
        self.assertIn('.accessibilityAction(named: L10n.format("重置%@", title), reset)', row)
        self.assertIn('.contextMenu { Button(L10n.format("重置%@", title), action: reset) }', row)

    def test_group_reset_has_a_distinct_accessibility_identifier(self):
        source = (ROOT / "RawLabMac/Sources/Controls/PhotoEffectsControls.swift").read_text()
        self.assertIn('accessibilityIdentifier("effects.resetGroup.', source)


if __name__ == "__main__":
    unittest.main()
