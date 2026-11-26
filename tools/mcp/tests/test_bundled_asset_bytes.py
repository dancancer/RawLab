import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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

    def test_catalog_snapshot_generator_check_fails_on_drift(self):
        generator = "scripts/catalog/generate.py"
        snapshot = "tools/mcp/src/rawlab_mcp/catalog_data.json"
        sources = [
            generator,
            "tools/mcp/src/rawlab_mcp/__init__.py",
            "tools/mcp/src/rawlab_mcp/catalog.py",
            snapshot,
            "Shared/master-recipes.json",
            "Shared/BundledLooks/catalog.json",
            "Shared/assets-manifest.json",
            *(p.relative_to(ROOT).as_posix() for p in (ROOT / "Shared/BundledLooks/HDR").glob("* Master.json")),
        ]
        with tempfile.TemporaryDirectory(prefix="rawlab-catalog-gen-") as tmp:
            root = Path(tmp)
            for rel in sources:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, root / rel)
            cmd = [sys.executable, str(root / generator), "--check", "--root", str(root)]
            baseline = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

            recipes_path = root / "Shared/master-recipes.json"
            original_recipes = recipes_path.read_text(encoding="utf-8")
            recipes = json.loads(original_recipes)
            recipes[0]["name"] += " drift"
            recipes_path.write_text(json.dumps(recipes, ensure_ascii=False, indent=2), encoding="utf-8")
            self.assertNotEqual(subprocess.run(cmd, capture_output=True, text=True).returncode, 0)
            recipes_path.write_text(original_recipes, encoding="utf-8")

            snapshot_path = root / snapshot
            snapshot_path.write_bytes(snapshot_path.read_bytes() + b"\n")
            self.assertNotEqual(subprocess.run(cmd, capture_output=True, text=True).returncode, 0)

    def test_mcp_bundled_transfer_spec_and_catalog_bypass_repo_shadowing(self):
        pkg_dir = ROOT / "tools/mcp/src/rawlab_mcp"
        repo_spec = json.loads((ROOT / "Shared/specs/adjustment-fields-v1.json").read_text(encoding="utf-8"))
        expected_fields = {
            entry["field_id"]: {
                "value_type": entry["protocol"]["value_type"],
                "nullable": bool(entry["protocol"]["nullable"]),
                "min": entry["protocol"]["min"],
                "max": entry["protocol"]["max"],
                "exclusive_min": bool(entry["protocol"].get("exclusive_min", False)),
                "exclusive_max": bool(entry["protocol"].get("exclusive_max", False)),
                "non_empty": bool(entry["protocol"].get("non_empty", False)),
                "allowed_values": entry["protocol"].get("allowed_values"),
                "object_keys": entry["protocol"].get("object_keys"),
                "optional_keys": entry["protocol"].get("optional_keys"),
                "hdr_only": bool(entry["protocol"].get("hdr_only", False)),
                "sub_fields": entry["protocol"].get("sub_fields"),
            }
            for entry in repo_spec["fields"]
            if entry["protocol"].get("transferable")
        }

        with tempfile.TemporaryDirectory(prefix="rawlab-mcp-isolated-") as tmp:
            isolated_pkg = Path(tmp) / "rawlab_mcp"
            isolated_pkg.mkdir(parents=True)
            for fname in ("__init__.py", "errors.py", "gui_sync.py", "catalog.py", "transfer_spec.json", "catalog_data.json"):
                src = pkg_dir / fname
                if src.is_file():
                    shutil.copy2(src, isolated_pkg / fname)
            env = {k: v for k, v in os.environ.items() if k != "RAWLAB_REPO"}
            probe = (
                "import json, sys\n"
                f"sys.path.insert(0, {tmp!r})\n"
                "from rawlab_mcp import gui_sync, catalog\n"
                "assert gui_sync._discover_repo_spec_path() is None, 'repo shadowing active'\n"
                "assert catalog._discover_repo_shared() is None, 'catalog repo shadowing active'\n"
                "print(json.dumps({'fields': gui_sync._TRANSFER_FIELDS, 'catalog': catalog.load_catalog()}))\n"
            )
            out = subprocess.check_output(
                [sys.executable, "-c", probe],
                cwd=tmp,
                env=env,
                text=True,
            )
            loaded = json.loads(out)

        self.assertEqual(loaded["fields"], expected_fields)
        repo_master = json.loads((ROOT / "Shared/master-recipes.json").read_text(encoding="utf-8"))
        repo_bundled = json.loads((ROOT / "Shared/BundledLooks/catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(loaded["catalog"]["master_recipes"], repo_master)
        self.assertEqual(loaded["catalog"]["bundled_looks"], repo_bundled)


if __name__ == "__main__":
    unittest.main()
