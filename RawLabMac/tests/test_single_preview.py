"""Source contract for SwiftUI-owned comparison state; viewing state stays outside photo edits."""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SinglePreview(unittest.TestCase):
    def test_new_editor_defaults_to_current_result(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertIn("@State private var viewing = MacViewingState()", source)
        self.assertIn("var enabled = false", (ROOT / "Sources/Presentation/MacViewingState.swift").read_text())
        self.assertIn("viewing.enabled && model.canComparePreview", source)
        self.assertIn("imagePane(result", source)

    def test_every_open_resets_comparison_without_touching_edits(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertRegex(source, r"\.onChange\(of: model\.sourceRevision\)\s*\{[^}]*viewing.sourceChanged\(\)[^}]*fit\(\)")
        self.assertNotIn("compare", (ROOT / "Sources/Editor/Storage/EditPersistence.swift").read_text())

    def test_manual_toggle_survives_parameter_and_render_changes(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertIn("Button { viewing.toggle() }", source)
        self.assertIn(".task(id: model.sourceRevision)", source)
        model = "\n".join(path.read_text() for path in (ROOT / "Sources/Editor/Model").glob("EditorModel*.swift"))
        self.assertNotIn("MacViewingState", model)
        self.assertIn("let before = model.neutral", source)
        self.assertNotIn("MacViewingState", (ROOT / "Sources/Editor/Storage/EditPersistence.swift").read_text())


if __name__ == "__main__":
    unittest.main()
