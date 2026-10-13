import json
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "de", "fr", "ja", "es")
PRINTF = re.compile(r"%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:[hlLzjt]+)?[@diufegsc]", re.I)


def apple_catalog(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


class LocalizationTests(unittest.TestCase):
    def test_macos_photography_terms(self):
        catalog = apple_catalog(ROOT / "RawLabMac/Resources/en.lproj/Localizable.strings")
        for key, expected in {
            "对比": "Comparison",
            "显示裁切提示": "Show clipping warnings",
            "曝光基准": "Exposure reference",
            "匹配内嵌预览": "Match embedded preview",
        }.items():
            self.assertEqual(catalog[key], expected, key)

    def test_master_recipe_and_hsl_coverage(self):
        recipes = json.loads((ROOT / "Shared/master-recipes.json").read_text())
        keys = {recipe[field] for recipe in recipes for field in ("subtitle", "summary")}
        keys.update(("色相", "饱和度", "明度", "红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红", "重置 HSL"))
        for language in LANGUAGES:
            for client in ("RawLabMac", "RawLab/RawLab"):
                catalog = apple_catalog(ROOT / client / "Resources" / (language + ".lproj") / "Localizable.strings")
                self.assertTrue(keys <= catalog.keys(), (client, language, keys - catalog.keys()))
            catalog = json.loads((ROOT / "RawLabWindows/Resources/Localization" / (language + ".json")).read_text())
            self.assertTrue(keys <= catalog.keys(), (language, keys - catalog.keys()))

    def assert_parity(self, catalogs, signature):
        english = catalogs["en"]
        self.assertGreater(len(english), 100)
        for language, catalog in catalogs.items():
            self.assertEqual(set(english), set(catalog), language)
            for key, value in catalog.items():
                self.assertTrue(value.strip(), (language, key))
                expected = signature(key)
                if expected:
                    self.assertEqual(expected, signature(value), (language, key))

    def test_apple_catalogs_and_source_coverage(self):
        for client, sources in (("RawLabMac", ROOT / "RawLabMac/Sources"),
                                ("RawLab/RawLab", ROOT / "RawLab/RawLab")):
            catalogs = {lang: apple_catalog(ROOT / client / "Resources" / (lang + ".lproj") / "Localizable.strings")
                        for lang in LANGUAGES}
            self.assert_parity(catalogs, lambda s: sorted(PRINTF.findall(s.replace("%%", ""))))
            for source in list(sources.rglob("*.swift")) + list((ROOT / "Shared").glob("*.swift")):
                for raw in re.findall(r'L10n\.(?:text|format)\("((?:[^"\\]|\\.)*)"', source.read_text()):
                    key = json.loads('"' + raw + '"')
                    self.assertTrue(key in catalogs["en"], (source, key))
            for key in ("细节优先", "去噪优先", "自定义", "跟随系统"):
                self.assertIn(key, catalogs["en"])

    def test_android_catalogs(self):
        directories = {"en": "values", "zh-Hans": "values-b+zh+Hans", "de": "values-de",
                       "fr": "values-fr", "ja": "values-ja", "es": "values-es"}
        catalogs = {language: {element.attrib["name"]: "".join(element.itertext())
                               for element in ET.parse(ROOT / "RawLabAndroid/app/src/main/res" / directory / "strings.xml").getroot()}
                    for language, directory in directories.items()}
        self.assert_parity(catalogs, lambda s: sorted(PRINTF.findall(s.replace("%%", ""))))
        for source in (ROOT / "RawLabAndroid/app/src/main/java").rglob("*.kt"):
            for key in re.findall(r"R\.string\.(\w+)", source.read_text()):
                self.assertIn(key, catalogs["en"], (source, key))
        for recipe in json.loads((ROOT / "Shared/master-recipes.json").read_text()):
            self.assertIn("recipe_subtitle_" + recipe["id"], catalogs["en"])

    def test_windows_catalogs(self):
        catalogs = {language: json.loads((ROOT / "RawLabWindows/Resources/Localization" / (language + ".json")).read_text())
                    for language in LANGUAGES}
        self.assert_parity(catalogs, lambda s: sorted(re.findall(r"\{\d+(?:[^{}]*)\}", s)))
        for source in (ROOT / "RawLabWindows").glob("*.cs"):
            for raw in re.findall(r'Loc\.(?:Text|Format)\("((?:[^"\\]|\\.)*)"', source.read_text()):
                key = json.loads('"' + raw + '"')
                self.assertIn(key, catalogs["en"], (source, key))
        namespace = {"x": "http://schemas.microsoft.com/winfx/2006/xaml/presentation"}
        for source in (ROOT / "RawLabWindows").glob("*.xaml"):
            ET.parse(source)
            for key in re.findall(r"\{DynamicResource '([^']+)'\}", source.read_text()):
                self.assertIn(key, catalogs["en"], (source, key))


if __name__ == "__main__":
    unittest.main()
