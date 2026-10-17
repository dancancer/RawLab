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


def hits(pattern, skip=()):
    return [f"{path.name}:{number}: {line.strip()}"
            for path in SOURCES if path.name not in skip
            for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]


class InterfaceCopy(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
