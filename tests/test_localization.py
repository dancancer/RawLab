import json
import re
import shutil
import subprocess
import sys
import tempfile
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


class GeneratorSourceTests(unittest.TestCase):
    def test_generated_catalogs_have_no_unowned_entries(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/localization/generate.py"), "--check"],
            capture_output=True, text=True, cwd=ROOT,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_check_rejects_drift_missing_files_and_unowned_resources_without_writing(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-localization-") as name:
            root = Path(name)
            shutil.copytree(ROOT / "Shared/strings", root / "Shared/strings")
            self.assertEqual(self.run_generator(root).returncode, 0)
            self.assertEqual(self.run_generator(root, "--check").returncode, 0)
            path = root / "RawLabWindows/Resources/Localization/en.json"
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            self.assertNotEqual(self.run_generator(root, "--check").returncode, 0)
            self.assertEqual(path.read_bytes(), original + b"\n")
            path.unlink()
            self.assertNotEqual(self.run_generator(root, "--check").returncode, 0)
            path.write_bytes(original)
            rogue = root / "RawLabAndroid/app/src/main/res/values/extra.xml"
            rogue.write_text('<resources><string name="rogue">Unowned</string></resources>')
            self.assertIn("Unowned catalog", self.run_generator(root, "--check").stderr)

    def test_one_source_change_updates_all_four_clients(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-localization-") as name:
            root = Path(name)
            shutil.copytree(ROOT / "Shared/strings", root / "Shared/strings")
            path = root / "Shared/strings/common/catalog.json"
            source = json.loads(path.read_text())
            source["语言"]["en"] = "Changed language label"
            source["从文件导入"]["en"] = "Changed file source"
            source["照片"]["en"] = "Changed photo source"
            path.write_text(json.dumps(source, ensure_ascii=False))
            self.assertEqual(self.run_generator(root).returncode, 0)
            for native in ("RawLabMac/Resources/en.lproj/Localizable.strings",
                           "RawLab/RawLab/Resources/en.lproj/Localizable.strings",
                           "RawLabWindows/Resources/Localization/en.json",
                           "RawLabAndroid/app/src/main/res/values/strings.xml"):
                self.assertIn("Changed language label", (root / native).read_text(), native)
            ios = root / "RawLab/RawLab/Resources/en.lproj/Localizable.strings"
            self.assertIn('"从文件导入" = "Changed file source";', ios.read_text())
            android = root / "RawLabAndroid/app/src/main/res/values/strings.xml"
            self.assertIn('name="open_file">"Import from files"</string>', android.read_text())
            windows = root / "RawLabWindows/Resources/Localization/en.json"
            self.assertEqual(json.loads(windows.read_text())["照片"], "Photos")

    def run_generator(self, root, *arguments):
        return subprocess.run([sys.executable, str(ROOT / "scripts/localization/generate.py"),
                               "--root", str(root), *arguments], capture_output=True, text=True)


class GeneratorFormatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / "scripts/localization"))
        global formats
        import formats

    def test_native_placeholders_keep_types_precision_and_literal_percent(self):
        for style, native, neutral, slots in (
            ("apple", "%@ · %@%%", "{0} · {1}%", ["%@", "%@"]),
            ("android", "%1$+.1f · %2$d%%", "{0} · {1}%", ["%1$+.1f", "%2$d"]),
            ("windows", "{0:0.#} / {1:P1}", "{0} / {1}", ["{0:0.#}", "{1:P1}"]),
        ):
            self.assertEqual(formats.normalize(native, style), (neutral, slots))
            self.assertEqual(formats.render(neutral, slots, style), native)

    def test_reordered_placeholders_keep_argument_positions(self):
        self.assertEqual(formats.render("{1} / {0}%", ["%@", "%@"], "apple"), "%2$@ / %1$@%%")
        self.assertEqual(formats.render("{1} / {0}", ["%1$d", "%2$s"], "android"), "%2$s / %1$d")

    def test_dotnet_literal_braces_do_not_become_arguments(self):
        native = "{{0}} {0,8:0.#}"
        neutral, slots = formats.normalize(native, "windows")
        self.assertEqual((neutral, slots), ("{{0}} {0}", ["{0,8:0.#}"]))
        self.assertEqual(formats.render(neutral, slots, "windows"), native)

    def test_conflicting_formats_for_one_argument_are_not_silently_lost(self):
        for native, style in (("%1$d %1$s", "android"), ("{0:0.#} {0:P1}", "windows")):
            with self.assertRaises(ValueError):
                formats.normalize(native, style)

    def test_apple_escaping_round_trips(self):
        value = '引号 " 和反斜杠 \\、换行\n下一行\t结束'
        text = formats.apple_quote(value) + " = " + formats.apple_quote(value) + ";\n"
        self.assertEqual(formats.read_apple(text), {value: value})
        with self.assertRaises(ValueError):
            formats.read_apple(text + text)
        with self.assertRaises(ValueError):
            formats.read_apple(text + "invalid")

    def test_android_escaping_handles_resource_prefix_and_whitespace(self):
        for value, expected in (
            ('@a & <b> \' " \\ \n', r'"\@a &amp; &lt;b&gt; \' \" \\ \n"'),
            ("?help", r'"\?help"'),
        ):
            escaped = formats.android_quote(value)
            self.assertEqual(escaped, expected)
            element = ET.fromstring("<string>" + escaped + "</string>")
            self.assertEqual(formats.android_unquote(element.text), value)

    def test_missing_or_extra_arguments_are_rejected(self):
        for text in ("{1}", "no placeholder", "{0} {2}"):
            with self.assertRaises(ValueError):
                formats.render(text, ["%1$d"], "android")


class LocalizationTests(unittest.TestCase):

    def test_aligned_controls_reuse_macos_copy_in_every_language(self):
        sys.path.insert(0, str(ROOT / "scripts/localization"))
        from formats import android_unquote
        aligned = {
            "ios": (("指定长边", "自定义…"), ("向左旋转 90°", "逆时针 90°")),
            "windows": (("重新读取目录", "刷新目录"), ("三分网格", "网格"), ("导出长边像素", "长边像素")),
            "android": (("geometry_swap_ratio", "交换横纵比例"), ("output_size_error", "导出长边必须为 1-65535 像素。"),
                        ("message_as_shot_for_each_photo", "按每张照片")),
        }
        android = android_catalogs()
        for language in LANGUAGES:
            macos = apple_catalog(ROOT / "RawLabMac/Resources" / (language + ".lproj") / "Localizable.strings")
            catalogs = {
                "ios": apple_catalog(ROOT / "RawLab/RawLab/Resources" / (language + ".lproj") / "Localizable.strings"),
                "windows": windows_catalog(language),
                "android": android[language],
            }
            for client, pairs in aligned.items():
                for key, previous_or_source in pairs:
                    expected_key = previous_or_source if client == "android" else key
                    actual = catalogs[client].get(key)
                    if client == "android" and actual is not None:
                        actual = android_unquote(actual)
                    self.assertEqual(actual, macos[expected_key], (client, language, key))
                    if client != "android":
                        self.assertNotIn(previous_or_source, catalogs[client], (client, previous_or_source))
        self.assertEqual(android_unquote(android["zh-Hans"]["look_unavailable"]), "此外观文件不可用，请删除后重新导入。")
        self.assertIn("降噪预设", windows_catalog("en"))

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


class BatchSummaryTermTests(unittest.TestCase):
    # 批量摘要沿用编辑器里的叫法；开关关着写"停用"，"关闭"是关窗口按钮的词，英文会显示成 Close
    def test_batch_summaries_use_editor_terms(self):
        for path in ("RawLabMac/Sources/BatchExportView.swift", "RawLabWindows/BatchExportWindow.xaml.cs"):
            text = (ROOT / path).read_text()
            self.assertEqual([term for term in ("小波降噪", "粗颗粒降噪") if term in text], [], path)
            self.assertEqual(re.findall(r'(?:Loc\.Text|L10n\.text)\("开启"\) : (?:Loc\.Text|L10n\.text)\("关闭"\)|_ => Loc\.Text\("关闭"\)', text), [], path)


if __name__ == "__main__":
    unittest.main()
