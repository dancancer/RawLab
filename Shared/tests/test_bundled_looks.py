import hashlib
import json
import struct
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BundledLooksTests(unittest.TestCase):
    def test_ektar_is_a_distinct_reproducible_project_look(self):
        folder = ROOT / "Shared/BundledLooks"
        catalog = json.loads((folder / "catalog.json").read_text())
        self.assertEqual(len(catalog), 29)
        look = catalog[0]
        self.assertEqual(look["id"], "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65")
        self.assertEqual(look["name"], "EKTAR 100 Phuket v2 Strong")
        self.assertEqual(look["artworkName"], "ektar-100-phuket")
        cube = folder / look["fileName"]
        self.assertEqual(hashlib.sha256(cube.read_bytes()).hexdigest(), look["sha256"])
        text = cube.read_text()
        self.assertIn("#Gamma:F-Log2 to EKTAR 100 Phuket", text)
        self.assertIn("#Gamut:F-Gamut to ITU-R BT.709", text)
        self.assertIn("LUT_3D_SIZE 65", text)
        self.assertNotEqual(cube.name, "kodak_ektar_100.cube")
        self.assertTrue((ROOT / "RawLabMac/Resources/FilmIcons/ektar-100-phuket.png").is_file())

    def test_every_platform_packages_the_same_source_directory(self):
        for relative in ["RawLabMac/build.sh", "RawLabAndroid/app/build.gradle.kts",
                         "RawLabWindows/RawLabWindows.csproj", "RawLab/RawLab.xcodeproj/project.pbxproj"]:
            with self.subTest(platform=relative):
                self.assertTrue("Shared/BundledLooks" in (ROOT / relative).read_text(), relative)

    def test_complete_catalog_artwork_hashes_and_adaptation_evidence(self):
        folder = ROOT / "Shared/BundledLooks"
        catalog = json.loads((folder / "catalog.json").read_text())
        self.assertEqual(len({entry["id"] for entry in catalog}), 29)
        self.assertEqual(len({entry["fileName"] for entry in catalog}), 29)
        self.assertEqual(len(list(folder.glob("*.cube"))), 29)
        for entry in catalog:
            with self.subTest(look=entry["id"]):
                self.assertEqual(Path(entry["fileName"]).stem, entry["id"])
                self.assertEqual(hashlib.sha256((folder / entry["fileName"]).read_bytes()).hexdigest(), entry["sha256"])
                art = folder / "Artwork" / (entry["artworkName"] + ".png")
                if not art.exists():
                    art = ROOT / "RawLabMac/Resources/FilmIcons" / (entry["artworkName"] + ".png")
                data = art.read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                width, height = struct.unpack(">II", data[16:24])
                self.assertEqual(width, height)
                self.assertGreaterEqual(width, 256)
        report = json.loads((folder / "adaptation-report.json").read_text())
        self.assertEqual(len(report), 28)
        self.assertTrue((folder / "REDISTRIBUTION_BLOCKED.md").exists())
        for entry in report:
            if entry["resampled"]:
                self.assertLessEqual(entry["error"]["max"], .025)
                self.assertLessEqual(entry["error"]["p99"], .002)
            else:
                self.assertTrue(entry["sourcePayloadByteIdentical"])
            self.assertEqual(entry["redistribution"], "unconfirmed")

    def test_mac_packaging_requires_explicit_private_validation(self):
        for environment in [{}, {"RAWLAB_ALLOW_UNCLEARED_LUTS": "1", "RAWLAB_RELEASE": "1"}]:
            result = subprocess.run(["bash", str(ROOT / "RawLabMac/build.sh")], cwd=ROOT,
                                    env={"PATH": "/usr/bin:/bin", **environment}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("redistribution is unconfirmed", result.stderr)

    def test_all_new_artwork_has_matching_generation_provenance(self):
        folder = ROOT / "Shared/BundledLooks/Artwork"
        recorded = set()
        for path in folder.glob("generated-*.json"):
            for asset in json.loads(path.read_text())["assets"]:
                name = asset.get("file") or asset.get("filename") or asset["id"] + ".png"
                self.assertNotIn(name, recorded)
                recorded.add(name)
                self.assertEqual(hashlib.sha256((folder / name).read_bytes()).hexdigest(), asset["sha256"])
                self.assertTrue(asset["prompt"])
        self.assertEqual(recorded, {path.name for path in folder.glob("*.png")})
        self.assertEqual(len(recorded), 28)


if __name__ == "__main__":
    unittest.main()
