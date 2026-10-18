"""Source contract for SwiftUI-owned comparison state; no image pipeline changes."""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SinglePreview(unittest.TestCase):
    def test_new_editor_defaults_to_current_result(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertIn("@State private var compare = false", source)
        self.assertTrue(re.search(r"if compare[^\n]*imagePane\(base[^\n]*\}\s*imagePane\(result", source))

    def test_every_open_resets_comparison_without_touching_edits(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertRegex(source, r"\.onChange\(of: model\.file\)\s*\{[^}]*compare = false[^}]*fit\(\)")
        self.assertNotIn("compare", (ROOT / "Sources/Editor/Storage/EditPersistence.swift").read_text())

    def test_manual_toggle_survives_parameter_and_render_changes(self):
        source = (ROOT / "Sources/Editor/View/EditorView.swift").read_text()
        self.assertIn("Button { compare.toggle() }", source)
        self.assertEqual(len(re.findall(r"compare\s*=", source)), 2)
        model = "\n".join(path.read_text() for path in (ROOT / "Sources/Editor/Model").glob("EditorModel*.swift"))
        self.assertNotIn("compare", model)
        self.assertIn("let base = model.neutral { imagePane(base", source)


if __name__ == "__main__":
    unittest.main()
