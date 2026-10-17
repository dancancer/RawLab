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
    "外观": {"ja": ("ルック", "外観|スキン")},
    "导出": {"ja": (None, "エクスポート|輸出")},
    "导入": {"ja": (None, "インポート|輸入")},
    "显影": {"ja": ("現像", "開発")},
    "降噪": {"ja": (None, "ノイズ軽減|ノイズリダクション|ノイズ除去")},
    "目录": {"ja": ("フォルダ", "ディレクトリ|カタログ")},
    "张": {"ja": (None, "シート")},
    "序号": {"ja": (None, "シリアル")},
    "小红书": {"ja": ("小紅書", "Little Red Book")},
}
# 机器翻译留下、与词条无关的错词
MISTRANSLATIONS = {
    "ja": "未開封|原画|申請|スライス|閉店|すでに|リセットノイズ|してください…|を選択します$|何も選択しない",
}


def glossary_violations(language, strings):
    found = []
    for term, rules in GLOSSARY.items():
        required, forbidden = rules.get(language, (None, None))
        for key, value in strings.items():
            if term not in key:
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


if __name__ == "__main__":
    unittest.main()
