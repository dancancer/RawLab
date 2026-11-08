import hashlib
import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[3]


class BundledAssetBytesTests(unittest.TestCase):
    def test_hdr_recipes_reference_exact_bundled_look_bytes(self):
        folder = ROOT / "Shared/BundledLooks/HDR"
        looks = {hashlib.sha256(path.read_bytes()).hexdigest() for path in folder.glob("*.cube")}
        recipes = list(folder.glob("*.json"))
        self.assertTrue(looks)
        self.assertTrue(recipes)
        for path in recipes:
            with self.subTest(recipe=path.name):
                look = json.loads(path.read_text(encoding="utf-8"))["values"]["hdr.look"]
                self.assertIn(look["sha256"], looks)

    def test_sdr_catalog_references_exact_bundled_look_bytes(self):
        folder = ROOT / "Shared/BundledLooks"
        for look in json.loads((folder / "catalog.json").read_text(encoding="utf-8")):
            with self.subTest(look=look["fileName"]):
                self.assertEqual(look["sha256"], hashlib.sha256((folder / look["fileName"]).read_bytes()).hexdigest())

    def test_bundled_look_bytes_are_protected_from_checkout_conversion(self):
        patterns = (
            "Shared/BundledLooks/HDR/*",
            "Shared/BundledLooks/*.cube",
            "lutools/flog-2-new/*.cube",
            "RawLabMac/Resources/MasterRecipes/*.cube",
        )
        for pattern in patterns:
            paths = sorted(path.relative_to(ROOT).as_posix() for path in ROOT.glob(pattern) if path.is_file())
            self.assertTrue(paths, pattern)
            attributes = subprocess.check_output(
                ["git", "check-attr", "-z", "--stdin", "text"], cwd=ROOT,
                input=("\0".join(paths) + "\0").encode("utf-8"),
            ).decode("utf-8").strip("\0").split("\0")
            for path, attribute, value in zip(attributes[::3], attributes[1::3], attributes[2::3]):
                with self.subTest(asset=path):
                    self.assertEqual(attribute, "text")
                    self.assertEqual(value, "unset", "Byte-hashed bundled assets require -text")


if __name__ == "__main__":
    unittest.main()
