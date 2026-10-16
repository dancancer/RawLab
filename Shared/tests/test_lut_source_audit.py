import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("audit", Path(__file__).parents[1] / "audit-lut-sources.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class SourceAuditTests(unittest.TestCase):
    def test_missing_domain_is_reported_without_inventing_a_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / "sample.cube"
            path.write_text('TITLE "sample sRGB"\nLUT_3D_SIZE 2\n' + '0 0 0\n' * 8)
            row = audit.inspect(path, root)
            self.assertIsNone(row["domainMin"])
            self.assertIsNone(row["domainMax"])
            self.assertEqual(row["declarations"], {})
            self.assertEqual(row["rows"], 8)
            original = row["semanticSha256"]
            path.write_text(path.read_text().replace("LUT_3D_SIZE", "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\nLUT_3D_SIZE"))
            self.assertNotEqual(audit.inspect(path, root)["semanticSha256"], original)

    def test_nonfinite_and_incomplete_tables_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / "bad.cube"
            for data in ['0 0 0\n' * 7, 'nan 0 0\n' * 8]:
                path.write_text('LUT_3D_SIZE 2\n' + data)
                with self.assertRaises(ValueError):
                    audit.inspect(path, root)


if __name__ == "__main__":
    unittest.main()
