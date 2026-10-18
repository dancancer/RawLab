"""界面文案契约：显示给用户的名称都要经过当前界面语言。"""
import json
import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = sorted((ROOT / "Sources").glob("*.swift"))
# 字符串字面量或行注释，谁先出现取谁：注释里的引号不算字面量
TOKEN = re.compile(r'"(?:[^"\\\n]|\\.)*"|//.*')
CJK_PUNCTUATION = re.compile(r"[：，。、；！？（）「」]")


def catalog(language):
    path = ROOT / "Resources" / (language + ".lproj") / "Localizable.strings"
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def literals(path):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for token in TOKEN.findall(line):
            if token.startswith("//"):
                break
            try:
                yield number, json.loads(token)
            except ValueError:  # Swift 插值等非 JSON 转义，原样比较
                yield number, token[1:-1]


# ----------------------------------------------------------------------------
#  术语表：同一个中文概念在一种语言里只用一种叫法
#  {中文词: {语言: (必须出现的写法, 不许出现的写法)}}，作用于键里含该中文词的所有条目
# ----------------------------------------------------------------------------
GLOSSARY = {
    "外观": {"en": (r"\blooks?\b", "appearance|skin"),
             "de": (r"\bLooks?\b", "Erscheinungsbild|Darstellung|Auftritt|Aussehen|Skin"),
             "fr": (r"\blooks?\b", "apparence|rendu|skin"),
             "es": (r"\blooks?\b", "aparienc|aspecto|máscara"),
             "ja": ("ルック", "外観|スキン")},
    "导出": {"ja": (None, "エクスポート|輸出")},
    "导入": {"ja": (None, "インポート|輸入")},
    "显影": {"fr": ("[Dd]éveloppement", None), "es": ("[Rr]evela", "[Dd]esarroll"), "ja": ("現像", "開発")},
    "渲染型": {"de": ("ntwickelt", "gerendert"), "fr": ("développé", "rendu"), "es": ("revelado", "renderizado"),
              "ja": ("現像済み", "レンダリング")},
    "降噪": {"de": (None, "Geräusch"), "es": (None, "crudo"), "ja": (None, "ノイズ軽減|ノイズリダクション|ノイズ除去")},
    "RAW": {"es": (None, "crudo")},
    "目录": {"en": ("folder", "director|catalog"), "de": ("Ordner", "Verzeichnis|Katalog"),
             "fr": ("dossier", "répertoire|catalogue"), "es": ("carpeta", "directorio|catálogo"),
             "ja": ("フォルダ", "ディレクトリ|カタログ")},
    "张": {"en": (None, "sheet"), "de": (None, "Blatt|Blätt"), "fr": (None, "feuille"), "es": (None, "hoja"),
           "ja": (None, "シート")},
    "序号": {"en": (None, "serial"), "de": (None, "Serien"), "fr": (None, "série"), "es": (None, "serie"),
             "ja": (None, "シリアル")},
    "小红书": {"en": ("Xiaohongshu", "Little Red Book"), "de": ("Xiaohongshu", "Little Red Book"),
              "fr": ("Xiaohongshu", "Petit Livre"), "es": ("Xiaohongshu", "Pequeño Libro"),
              "ja": ("小紅書", "Little Red Book")},
    "羽化": {"de": (None, "^Federn$"), "fr": (None, "drapeau")},
    # 菜单里的"批量导出"与"查看批量任务"是同一件事，叫法一致
    "批量": {"de": ("Stapel", "Batch"), "fr": ("par lots", "batch"), "es": ("por lotes", None),
             "ja": ("一括", "バッチ")},
    "高光保护": {"fr": (None, "surbrillance"), "es": (None, "destacada")},
    # "=" 开头只匹配整个键：白平衡的色调（Tint）不能与 HSL 的色相（Farbton）同名
    "=色调": {"de": ("^Tönung$", None)},
}
# 机器翻译留下、与词条无关的错词；按钮、菜单和提示用动词原形，不用命令式整句
MISTRANSLATIONS = {
    "en": "Already turned|Display in film|after application|benchmark|Close prompt|Haven't|Projects and authors"
          "|^Select photo…$",
    "de": "Eingabeaufforderung|Habe noch|im Film|nach der Anwendung|Benchmark|Benutzerauftritt|Einzelheiten"
          "|^Ergebnisse importieren$|^(Suchen|Versuchen|Geben|Wählen|Zeigen|Entfernen|Setzen|Öffnen|Verwenden"
          "|Passen|Exportieren|Gehen) Sie",
    "fr": "Je n'ai|au cinéma|après application|Projets et auteurs|^Importer les résultats$|l'invite"
          "|^Développer…$|^N'en sélectionner|^(Vérifiez|Sélectionnez|Ouvrez|Réessayez|Allez)",
    "es": "Aún no he|en película|de la aplicación|Proyectos y autores|^Importar resultados$|^No seleccionar ninguno$"
          "|^(Busque|Seleccione|Utilice|Ajuste el|Inténtalo)",
    "ja": "未開封|原画|申請|スライス|閉店|すでに|リセットノイズ|してください…|を選択します$|何も選択しない",
}


def glossary_violations(language, strings):
    found = []
    for term, rules in GLOSSARY.items():
        required, forbidden = rules.get(language, (None, None))
        for key, value in strings.items():
            if (key != term[1:]) if term.startswith("=") else (term not in key):
                continue
            if required and not re.search(required, value, re.I):
                found.append(f"{key} = {value} (needs {required})")
            if forbidden and re.search(forbidden, value, re.I):
                found.append(f"{key} = {value} (uses {forbidden})")
    pattern = MISTRANSLATIONS.get(language)
    found += [f"{key} = {value}" for key, value in strings.items() if pattern and re.search(pattern, value)]
    return found


def hits(pattern, skip=()):
    return [f"{path.name}:{number}: {line.strip()}"
            for path in SOURCES if path.name not in skip
            for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]


class InterfaceCopy(unittest.TestCase):
    maxDiff = None

    # ------------------------------------------------------------------------
    #  配方名是翻译键：界面只能显示 title
    #  共享检查按单词边界匹配 recipe/masterRecipe，漏掉 selectedMasterRecipe 这类写法
    # ------------------------------------------------------------------------
    def test_recipe_names_are_shown_through_titles(self):
        raw = re.compile(r"[Rr]ecipe\??\.name\b")
        self.assertEqual(hits(raw, skip={"MasterRecipe.swift"}), [])

    # ------------------------------------------------------------------------
    #  批量任务的外观名随任务保存：中性存的是翻译键"中性"，显示时再按当前语言翻译
    # ------------------------------------------------------------------------
    def test_batch_look_name_is_translated_when_shown(self):
        view = (ROOT / "Sources/BatchExportView.swift").read_text()
        shown = view.count("model.job.lookName")
        self.assertGreater(shown, 0)
        self.assertEqual(view.count("L10n.text(model.job.lookName)"), shown)

    # ------------------------------------------------------------------------
    #  中文标点只能出现在翻译键里：拼接出来的"名称：原因"在英文界面也会带全角冒号
    # ------------------------------------------------------------------------
    def test_cjk_punctuation_only_lives_in_catalog_keys(self):
        keys = catalog("en")
        found = [f"{path.name}:{number}: {text}" for path in SOURCES for number, text in literals(path)
                 if CJK_PUNCTUATION.search(text) and text not in keys]
        self.assertEqual(found, [])

    # ------------------------------------------------------------------------
    #  选项文字随语言变长：弹出菜单按最长选项取宽度，外观名不设固定上限
    #  写死宽度时德文"An eingebettete Vorschau anpassen""Einstellung wie aufgenommen"被截断
    # ------------------------------------------------------------------------
    def test_localized_pickers_and_look_label_are_not_capped(self):
        editor = (ROOT / "Sources/EditorView.swift").read_text()
        dock = (ROOT / "Sources/AdjustmentDock.swift").read_text()
        exposure = editor[editor.index('Picker(L10n.text("曝光基准")'):editor.index('.help(L10n.text("曝光基准"))')]
        balance = dock[dock.index('Picker(L10n.text("白平衡")'):dock.index("parameterRow(.temperature)")]
        look = editor[editor.index('"%@ · 大师配方"'):editor.index("Spacer(minLength: 8)")]
        for name, block in (("exposure reference", exposure), ("white balance", balance)):
            self.assertIn(".fixedSize()", block, name)
            self.assertNotRegex(block, r"\.frame\((max)?[wW]idth:", name)
        self.assertNotIn("maxWidth:", look)

    # ------------------------------------------------------------------------
    #  开关状态统一用"开启/停用"的译法：键"关闭"是关窗口的动词，英文是 "Close"；
    #  "已开启/已关闭"曾被译成 "Already turned on/Closed"、"閉店"
    # ------------------------------------------------------------------------
    def test_on_off_states_use_state_words(self):
        view = (ROOT / "Sources/BatchExportView.swift").read_text()
        self.assertEqual(view.count('L10n.text("开启") : L10n.text("关闭")'), 0)
        for language in ("en", "de", "fr", "es", "ja"):
            strings = catalog(language)
            self.assertEqual(strings["已开启"], strings["开启"], language)
            self.assertEqual(strings["已关闭"], strings["停用"], language)

    # ------------------------------------------------------------------------
    #  译文按术语表统一，不再出现"輸入外観""開発中""写真は未開封です"这类错词
    # ------------------------------------------------------------------------
    def test_catalogs_follow_the_glossary(self):
        for language in ("en", "de", "fr", "es", "ja"):
            self.assertEqual(glossary_violations(language, catalog(language)), [], language)

    # ------------------------------------------------------------------------
    #  工具栏开关要看得出开没开：macOS 26 的工具栏忽略 .tint，对比、照片信息、
    #  调整栏三个开关打开后外观毫无变化；改为开启时把图标染成黄色
    # ------------------------------------------------------------------------
    def test_toolbar_toggles_show_their_state(self):
        editor = (ROOT / "Sources/EditorView.swift").read_text()
        toolbar = editor[editor.index("private var editorToolbar"):editor.index("private func reset(")]
        self.assertNotIn(".tint(", toolbar)
        for state in ("compare", "infoMode != .hidden", "!adjustmentPanel.collapsed"):
            self.assertIn(f".activeTint({state})", toolbar)

    # ------------------------------------------------------------------------
    #  "窗口"菜单里的"批量导出"随时可点：还没有任务时不能打开一个空白窗口
    # ------------------------------------------------------------------------
    def test_batch_window_has_an_empty_state(self):
        app = (ROOT / "Sources/RawLabMacApp.swift").read_text()
        scene = app[app.index('Window(L10n.text("批量导出"), id: "batch-export")'):]
        self.assertRegex(scene[:400], r"if let batch = model\.batch \{.*\} else \{\s*BatchExportEmptyView\(\)")

    # ------------------------------------------------------------------------
    #  工具栏"导出"菜单与批量导出的格式选择用同一套格式名：
    #  曾是"JPEG… / PNG · 16 位… / 导出渲染型 DNG…"，对面是"JPEG / 16 位 PNG / DNG · 渲染型"
    # ------------------------------------------------------------------------
    def test_export_menu_uses_the_format_names(self):
        editor = (ROOT / "Sources/EditorView.swift").read_text()
        menu = editor[editor.index("Menu {", editor.index('.keyboardShortcut("a"')):editor.index('L10n.text("使用当前调整批量导出…")')]
        self.assertIn("ForEach(ExportFormat.allCases)", menu)
        self.assertIn('format.title + "…"', menu)
        for label in ('"JPEG…"', '"PNG · 16-bit…"', '"导出渲染型 DNG…"'):
            self.assertNotIn(label, menu)

    # ------------------------------------------------------------------------
    #  同一个数值在各处写法一致：批量导出的"全部调整"曾把 +0.40 EV 写成 "0.40EV"，
    #  与上方摘要、编辑框都不一样
    # ------------------------------------------------------------------------
    def test_adjustment_values_share_one_format(self):
        view = (ROOT / "Sources/BatchExportView.swift").read_text()
        self.assertNotIn("spec.text(model.job.settings[keyPath: spec.keyPath]) + spec.unit", view)
        self.assertNotIn('String(format: "%+.2f EV"', view)
        self.assertIn("spec.display(model.job.settings[keyPath: spec.keyPath])", view)

    # ------------------------------------------------------------------------
    #  同一面板不重复显示同一个数值：批量导出摘要已列出曝光，"全部调整"展开后不再列一次
    # ------------------------------------------------------------------------
    def test_batch_summary_does_not_repeat_exposure(self):
        view = (ROOT / "Sources/BatchExportView.swift").read_text()
        summary = view[view.index('Text(L10n.text("调整来源"))'):view.index('DisclosureGroup(L10n.text("全部调整"))')]
        full = view[view.index('DisclosureGroup(L10n.text("全部调整"))'):view.index('Text(L10n.text("输出"))')]
        self.assertIn("AdjustmentParameter.exposure", summary)
        self.assertIn("AdjustmentParameter.allCases.filter { $0 != .exposure }", full)


if __name__ == "__main__":
    unittest.main()
