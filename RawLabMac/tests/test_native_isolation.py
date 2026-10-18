"""原生测试不得读写用户日常的 RawLab 资料目录。"""
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
# EditorModel 的三个目录参数缺省时指向 ~/Library/Application Support/RawLab
DIRECTORIES = ("lookDirectory:", "editDirectory:", "batchDirectory:")


def calls(source, name):
    """逐个取出 name(...) 调用的完整参数文本，括号可以跨行"""
    start = source.find(name + "(")
    while start >= 0:
        depth, index = 0, start + len(name)
        while True:
            depth += {"(": 1, ")": -1}.get(source[index], 0)
            index += 1
            if depth == 0:
                break
        yield source.count("\n", 0, start) + 1, source[start:index]
        start = source.find(name + "(", index)


class NativeIsolation(unittest.TestCase):
    # ------------------------------------------------------------------------
    #  测试里的编辑模型必须指定外观、编辑记录、批量任务三个目录
    #  缺一个就会写进用户真实的 edits.json 或批量任务记录
    # ------------------------------------------------------------------------
    def test_editor_models_use_private_directories(self):
        # 自带 EditorModel 替身的测试不碰真实目录，跳过
        sources = [path for path in sorted((ROOT / "tests").rglob("*.swift")) if "class EditorModel" not in path.read_text()]
        leaks = [f"{path.name}:{line}"
                 for path in sources
                 for line, call in calls(path.read_text(), "EditorModel")
                 if not all(argument in call for argument in DIRECTORIES)]
        self.assertEqual(leaks, [])


if __name__ == "__main__":
    unittest.main()
