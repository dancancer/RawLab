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
        manifest = json.loads((ROOT / "Shared/assets-manifest.json").read_text(encoding="utf-8"))
        manifest_hashes = {
            entry["path"]: entry["sha256"] for entry in manifest["groups"]["luts"]["files"]
        }
        for look in json.loads((folder / "catalog.json").read_text(encoding="utf-8")):
            rel = f"Shared/BundledLooks/{look['fileName']}"
            with self.subTest(look=look["fileName"]):
                self.assertEqual(look["sha256"], manifest_hashes.get(rel))
                cube = folder / look["fileName"]
                if cube.is_file():
                    self.assertEqual(look["sha256"], hashlib.sha256(cube.read_bytes()).hexdigest())

    def test_bundled_look_bytes_are_protected_from_checkout_conversion(self):
        manifest = json.loads((ROOT / "Shared/assets-manifest.json").read_text(encoding="utf-8"))
        manifest_cubes = [entry["path"] for entry in manifest["groups"]["luts"]["files"]]
        hdr_paths = sorted(
            path.relative_to(ROOT).as_posix()
            for path in ROOT.glob("Shared/BundledLooks/HDR/*")
            if path.is_file()
        )
        self.assertTrue(hdr_paths, "Shared/BundledLooks/HDR/*")
        protected_prefixes = (
            "Shared/BundledLooks/",
            "lutools/flog-2-new/",
            "RawLabMac/Resources/MasterRecipes/",
        )
        lut_paths = sorted(
            path for path in manifest_cubes if path.startswith(protected_prefixes)
        )
        self.assertEqual(len(lut_paths), 55)
        paths = hdr_paths + lut_paths
        attributes = subprocess.check_output(
            ["git", "check-attr", "-z", "--stdin", "text"], cwd=ROOT,
            input=("\0".join(paths) + "\0").encode("utf-8"),
        ).decode("utf-8").strip("\0").split("\0")
        for path, attribute, value in zip(attributes[::3], attributes[1::3], attributes[2::3]):
            with self.subTest(asset=path):
                self.assertEqual(attribute, "text")
                self.assertEqual(value, "unset", "Byte-hashed bundled assets require -text")

    def test_mcp_catalog_matches_repo_sources_without_external_paths(self):
        import sys
        sys.path.insert(0, str(ROOT / "tools/mcp/src"))
        from rawlab_mcp import catalog  # noqa: E402

        catalog_src = (ROOT / "tools/mcp/src/rawlab_mcp/catalog.py").read_text(encoding="utf-8")
        self.assertNotIn(".gemini", catalog_src)

        repo_master = json.loads((ROOT / "Shared/master-recipes.json").read_text(encoding="utf-8"))
        repo_bundled = json.loads((ROOT / "Shared/BundledLooks/catalog.json").read_text(encoding="utf-8"))
        bundled_snapshot = json.loads((ROOT / "tools/mcp/src/rawlab_mcp/catalog_data.json").read_text(encoding="utf-8"))

        self.assertEqual(bundled_snapshot["master_recipes"], repo_master)
        self.assertEqual(bundled_snapshot["bundled_looks"], repo_bundled)

        listed = catalog.list_looks(category="all")
        self.assertEqual(listed["counts"]["master_recipe"], len(repo_master))
        self.assertEqual(listed["counts"]["bundled"], len(repo_bundled))
        self.assertEqual(listed["counts"]["fuji_flog2"], 16)
        self.assertEqual(listed["counts"]["hdr"], 1)


if __name__ == "__main__":
    unittest.main()
