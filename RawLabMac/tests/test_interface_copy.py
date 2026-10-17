"""界面文案契约：显示给用户的名称都要经过当前界面语言。"""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = sorted((ROOT / "Sources").glob("*.swift"))


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


if __name__ == "__main__":
    unittest.main()
