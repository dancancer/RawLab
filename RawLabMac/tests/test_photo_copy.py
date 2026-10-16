"""Copy contracts for workflows that accept both RAW and ordinary photos."""
import json
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PhotoCopy(unittest.TestCase):
    def test_batch_import_copy_is_not_raw_only(self):
        source = (ROOT / "Sources/BatchExportView.swift").read_text()
        for key in ("添加照片", "正在检查照片…", "尚未选择照片"):
            self.assertIn(f'L10n.text("{key}")', source)
        for key in ("添加 RAW", "正在检查 RAW 照片…", "尚未选择 RAW"):
            self.assertNotIn(f'L10n.text("{key}")', source)

    def test_editor_loading_and_retry_copy_is_not_raw_only(self):
        source = (ROOT / "Sources/EditorView.swift").read_text()
        self.assertIn('L10n.text("照片")', source)
        self.assertNotIn('L10n.text("RAW 照片")', source)
        self.assertNotIn('L10n.text("打开其他 RAW…")', source)
        self.assertIn('Button(L10n.text("打开照片"), action: model.openPanel)', source)

    def test_generic_photo_copy_is_translated_in_all_six_languages(self):
        for language in ("en", "de", "es", "fr", "ja", "zh-Hans"):
            with self.subTest(language=language):
                path = ROOT / "Resources" / f"{language}.lproj" / "Localizable.strings"
                translations = json.loads(subprocess.check_output(
                    ["plutil", "-convert", "json", "-o", "-", str(path)], text=True))
                for key in ("添加照片", "正在检查照片…", "尚未选择照片", "照片", "打开照片"):
                    self.assertTrue(translations.get(key), f"{language}: {key}")
                    self.assertNotIn("RAW", translations[key])


if __name__ == "__main__":
    unittest.main()
