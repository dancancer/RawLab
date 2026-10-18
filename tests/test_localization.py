import json
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "de", "fr", "ja", "es")
PRINTF = re.compile(r"%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:[hlLzjt]+)?[@diufegsc]", re.I)
APPLE_CLIENTS = {"RawLabMac": "RawLabMac/Sources", "RawLab/RawLab": "RawLab/RawLab"}
CJK = re.compile(r"[一-鿿]")
# 字符串字面量或行注释，谁先出现取谁：注释里的引号不算字面量
TOKEN = re.compile(r'"(?:[^"\\\n]|\\.)*"|//.*')


def apple_catalog(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def windows_catalog(language):
    return json.loads((ROOT / "RawLabWindows/Resources/Localization" / (language + ".json")).read_text())


def decode(literal):
    try:
        return json.loads(literal)
    except ValueError:  # Swift 插值等非 JSON 转义，原样比较
        return literal[1:-1]


def code_literals(path):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for token in TOKEN.findall(line):
            if token.startswith("//"):
                break
            yield number, line, decode(token)


def untranslated(files, catalog, call):
    """既不是翻译键、也不在翻译调用里的中文字面量；本地化模块自身的母语名称除外"""
    return sorted(f"{path.relative_to(ROOT)}:{number}: {text}"
                  for path in files if path.stem != "Localization"
                  for number, line, text in code_literals(path)
                  if CJK.search(text) and text not in catalog and call not in line)


def xaml_literals(path):
    """XAML 属性值或元素正文里的中文：界面文字只能经由 DynamicResource；Tag 是给代码用的标识，不显示"""
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for name, value, body in re.findall(r'([\w.:]+)="([^"{][^"]*)"|>([^<>]+)<', line):
            text = body or (value if name != "Tag" else "")
            if CJK.search(text):
                yield f"{path.name}:{number}: {text.strip()}"


def android_catalogs():
    directories = {"en": "values", "zh-Hans": "values-b+zh+Hans", "de": "values-de",
                   "fr": "values-fr", "ja": "values-ja", "es": "values-es"}
    return {language: {element.attrib["name"]: "".join(element.itertext())
                       for path in (ROOT / "RawLabAndroid/app/src/main/res" / directory).glob("*.xml")
                       for element in ET.parse(path).getroot() if element.tag == "string"}
            for language, directory in directories.items()}


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
            for client in APPLE_CLIENTS:
                catalog = apple_catalog(ROOT / client / "Resources" / (language + ".lproj") / "Localizable.strings")
                self.assertTrue(keys <= catalog.keys(), (client, language, keys - catalog.keys()))
            catalog = windows_catalog(language)
            self.assertTrue(keys <= catalog.keys(), (language, keys - catalog.keys()))

    def test_recipe_names_are_localized(self):
        # 配方名是数据：汉字写的人名也要按语言显示（拉丁字母语言用罗马字，日文用日文汉字）
        recipes = json.loads((ROOT / "Shared/master-recipes.json").read_text())
        names = {recipe["name"] for recipe in recipes if CJK.search(recipe["name"])}
        self.assertTrue(names)
        for language in LANGUAGES:
            catalogs = {client: apple_catalog(ROOT / client / "Resources" / (language + ".lproj") / "Localizable.strings")
                        for client in APPLE_CLIENTS}
            catalogs["RawLabWindows"] = windows_catalog(language)
            for client, catalog in catalogs.items():
                self.assertTrue(names <= catalog.keys(), (client, language, names - catalog.keys()))
                if language in ("en", "de", "fr", "es"):
                    self.assertEqual([catalog[n] for n in names if CJK.search(catalog[n])], [], (client, language))
        # 界面只经由翻译显示配方名：用翻译后的 title，或直接包在翻译调用里
        raw = re.compile(r"(?<!L10n\.text\()(?<!Loc\.Text\()\b\w*[Rr]ecipe\??\.(?:name|Name)\b")
        # 对配方做 map 时闭包里的 $0 也是配方
        mapped = re.compile(r"[Rr]ecipe\w*\??\.map\b.*\$0\.name\b")
        sources = [*(ROOT / "RawLabMac/Sources").glob("*.swift"), *(ROOT / "RawLab/RawLab/UI").rglob("*.swift"),
                   *(ROOT / "RawLabWindows").glob("*.cs")]
        hits = [f"{p.relative_to(ROOT)}:{n}" for p in sources for n, line in enumerate(p.read_text().splitlines(), 1)
                if raw.search(line) or mapped.search(line)]
        self.assertEqual(hits, [])

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
        for client, sources in APPLE_CLIENTS.items():
            catalogs = {lang: apple_catalog(ROOT / client / "Resources" / (lang + ".lproj") / "Localizable.strings")
                        for lang in LANGUAGES}
            self.assert_parity(catalogs, lambda s: sorted(PRINTF.findall(s.replace("%%", ""))))
            missing = sorted({(source.name, json.loads('"' + raw + '"'))
                              for source in list((ROOT / sources).rglob("*.swift")) + list((ROOT / "Shared").glob("*.swift"))
                              for raw in re.findall(r'L10n\.(?:text|format)\("((?:[^"\\]|\\.)*)"', source.read_text())
                              if json.loads('"' + raw + '"') not in catalogs["en"]})
            self.assertEqual(missing, [], client)
            for key in ("细节优先", "去噪优先", "自定义", "跟随系统"):
                self.assertIn(key, catalogs["en"])

    def test_source_literals_are_translated(self):
        for client, sources in APPLE_CLIENTS.items():
            catalog = apple_catalog(ROOT / client / "Resources/en.lproj/Localizable.strings")
            files = list((ROOT / sources).rglob("*.swift")) + list((ROOT / "Shared").glob("*.swift"))
            self.assertEqual(untranslated(files, catalog, "L10n."), [], client)
        windows = ROOT / "RawLabWindows"
        self.assertEqual(untranslated(windows.glob("*.cs"), windows_catalog("en"), "Loc."), [], "RawLabWindows")
        self.assertEqual([hit for path in windows.glob("*.xaml") for hit in xaml_literals(path)], [], "XAML")

    def test_ui_labels_start_with_capital(self):
        for language in ("en", "de", "fr", "es"):
            catalogs = {client: apple_catalog(ROOT / client / "Resources" / (language + ".lproj") / "Localizable.strings")
                        for client in APPLE_CLIENTS}
            catalogs["RawLabWindows"] = windows_catalog(language)
            for client, catalog in catalogs.items():
                lower = {key: value for key, value in catalog.items() if value[:1].islower()}
                self.assertEqual(lower, {}, (client, language))

    def test_android_catalogs(self):
        catalogs = android_catalogs()
        self.assert_parity(catalogs, lambda s: sorted(PRINTF.findall(s.replace("%%", ""))))
        missing = sorted({(source.name, key) for source in (ROOT / "RawLabAndroid/app/src/main/java").rglob("*.kt")
                          for key in re.findall(r"R\.string\.(\w+)", source.read_text()) if key not in catalogs["en"]})
        self.assertEqual(missing, [])
        for recipe in json.loads((ROOT / "Shared/master-recipes.json").read_text()):
            self.assertIn("recipe_subtitle_" + recipe["id"], catalogs["en"])

    def test_android_dng_description_uses_the_look_term(self):
        # 导入的外观统一叫 Look：渲染型 DNG 的说明也用同一个词，不另造“appearance”之类的说法
        catalogs = android_catalogs()
        terms = {"en": "look", "zh-Hans": "外观", "de": "Look", "fr": "look", "ja": "ルック", "es": "look"}
        for language, term in terms.items():
            for key in ("import_look", "dng_description"):
                self.assertIn(term.lower(), catalogs[language][key].lower(), (language, key))

    def test_android_recipe_names_are_localized(self):
        # 汉字写的人名配方按语言显示：资源名 recipe_name_<id>；拉丁字母语言不得出现汉字
        catalogs = android_catalogs()
        recipes = json.loads((ROOT / "Shared/master-recipes.json").read_text())
        keys = {"recipe_name_" + recipe["id"] for recipe in recipes if CJK.search(recipe["name"])}
        self.assertTrue(keys)
        for language, catalog in catalogs.items():
            self.assertTrue(keys <= catalog.keys(), (language, keys - catalog.keys()))
            if language in ("en", "de", "fr", "es"):
                self.assertEqual([key for key in keys if CJK.search(catalog[key])], [], language)
        # 界面只经由 AppStrings.recipeName 显示配方名，不直接取原始 name
        raw = re.compile(r"\b(?:recipe|masterRecipe)\??\.name\b|recipes\.\w+\s*\{[^}]*\}\??\.name\b")
        sources = [path for path in (ROOT / "RawLabAndroid/app/src/main/java").rglob("*.kt") if path.name != "AppStrings.kt"]
        hits = [f"{p.relative_to(ROOT)}:{n}" for p in sources for n, line in enumerate(p.read_text().splitlines(), 1)
                if raw.search(line)]
        self.assertEqual(hits, [])

    def test_windows_catalogs(self):
        catalogs = {language: windows_catalog(language) for language in LANGUAGES}
        self.assert_parity(catalogs, lambda s: sorted(re.findall(r"\{\d+(?:[^{}]*)\}", s)))
        windows = ROOT / "RawLabWindows"
        keys = {json.loads('"' + raw + '"') for source in windows.glob("*.cs")
                for raw in re.findall(r'Loc\.(?:Text|Format)\("((?:[^"\\]|\\.)*)"', source.read_text())}
        for source in windows.glob("*.xaml"):
            ET.parse(source)
            keys.update(re.findall(r"\{DynamicResource '([^']+)'\}", source.read_text()))
        self.assertEqual(sorted(keys - catalogs["en"].keys()), [])


# ----------------------------------------------------------------------------
#  数量不能写在复数名词前面：英德法西会出现"1 Photos""1 Fotos"
#  改写成"名词：数量"或"动作（数量）"，不需要单复数规则
# ----------------------------------------------------------------------------
PLURAL_NOUNS = {"en": "photos|files|looks|images", "de": "fotos|dateien|looks|bilder",
                "fr": "photos|fichiers|looks|images", "es": "fotos|archivos|looks|imágenes"}
COUNT = r"(?:%(?:\d+\$)?(?:l{0,2}d|@)|\{\d+\})"


class CountPhrasingTests(unittest.TestCase):
    def test_counts_do_not_precede_plural_nouns(self):
        android = android_catalogs()
        for language, nouns in PLURAL_NOUNS.items():
            pattern = re.compile(COUNT + r"(?:\s+[^\s:;,.()]+){0,3}?[\s-]+(?:" + nouns + r")\b", re.I)
            catalogs = {client: apple_catalog(ROOT / client / "Resources" / (language + ".lproj") / "Localizable.strings")
                        for client in APPLE_CLIENTS}
            catalogs["RawLabWindows"] = windows_catalog(language)
            catalogs["RawLabAndroid"] = android[language]
            found = [(client, value) for client, catalog in catalogs.items()
                     for value in catalog.values() if pattern.search(value)]
            self.assertEqual(found, [], language)


if __name__ == "__main__":
    unittest.main()
