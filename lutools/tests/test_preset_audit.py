import json
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from lutools.lutprep import audit as audit_module
from lutools.lutprep.audit import audit_sources
from lutools.lutprep.__main__ import main
from lutools.lutprep.native import compile_dcp
from lutools.tests.test_lutprep_dcp import write_dcp


def write_cube(path):
    path.write_text(
        'TITLE "untagged synthetic cube"\n'
        'LUT_3D_SIZE 2\n'
        'DOMAIN_MIN 0 0 0\n'
        'DOMAIN_MAX 1 1 1\n'
        '0 0 0\n0 0 1\n0 1 0\n0 1 1\n'
        '1 0 0\n1 0 1\n1 1 0\n1 1 1\n',
        encoding="utf-8",
    )
    return path


def write_xmp(path):
    path.write_text(
        '''<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
  <rdf:RDF><rdf:Description crs:Version="15.0" crs:CameraProfile="Camera Standard"
      crs:LookTableName="Embedded Look" crs:LookTableDims="2,2,1"
      crs:UnknownField="preserve-me" /></rdf:RDF>
</x:xmpmeta>
''',
        encoding="utf-8",
    )
    return path


def write_spi1d(path):
    path.write_text(
        "Version 1\nFrom 0.0 1.0\nLength 2\nComponents 1\n{\n0.0\n1.0\n}\n",
        encoding="utf-8",
    )
    return path


def write_clf(path):
    path.write_text(
        '''<?xml version="1.0" encoding="UTF-8"?>
<ProcessList id="synthetic" name="synthetic" version="1.0">
  <LUT1D inBitDepth="32f" outBitDepth="32f">
    <Array dim="2 1">0.0 1.0</Array>
  </LUT1D>
</ProcessList>
''',
        encoding="utf-8",
    )
    return path


def write_xmp_tables(path):
    payload = "A" * 2048
    path.write_text(
        f'''<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmlns:other="https://example.invalid/not-crs/">
  <rdf:RDF><rdf:Description crs:Table_42="{payload}" crs:LookTable="42"
      crs:RGBTable="99" other:Profile="not-a-crs-dependency" /></rdf:RDF>
</x:xmpmeta>
''',
        encoding="utf-8",
    )
    return path


def write_xmp_namespace_and_nested_payload(path):
    path.write_text(
        '''<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmlns:other="https://example.invalid/not-crs/">
  <rdf:RDF><rdf:Description other:Table_7="FOREIGN_PAYLOAD" other:LookTable="7"
      other:RGBTable="7"><other:Table_7><foo>FOREIGN_SECRET</foo></other:Table_7>
      <crs:Table_42><foo>SECRET_PAYLOAD</foo></crs:Table_42>
    </rdf:Description></rdf:RDF>
</x:xmpmeta>
''',
        encoding="utf-8",
    )
    return path


def snapshot(root):
    return {path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*") if path.is_file()}


class PresetAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def entry(self, report, name):
        return next(item for item in report["entries"] if item["path"] == name)

    def test_supported_dcp_is_read_only_and_compile_is_not_run_by_default(self):
        source = write_dcp(self.root / "synthetic.dcp")
        before = snapshot(self.root)

        result = subprocess.run(
            [sys.executable, "-m", "lutools.lutprep", "audit", str(self.root)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)

        self.assertEqual(report["version"], 1)
        entry = self.entry(report, "synthetic.dcp")
        self.assertEqual(entry["format"], "dcp")
        self.assertEqual(entry["read"]["status"], "passed")
        self.assertEqual(entry["compile"]["status"], "not_run")
        self.assertEqual(entry["appearance"]["status"], "unverified")
        self.assertEqual(source.read_bytes(), before["synthetic.dcp"])
        self.assertEqual(snapshot(self.root), before)

    def test_verify_compile_uses_temporary_rlook_and_reads_it_back(self):
        write_dcp(self.root / "synthetic.dcp")
        before = snapshot(self.root)

        result = subprocess.run(
            [sys.executable, "-m", "lutools.lutprep", "audit", str(self.root), "--verify-compile"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)

        entry = self.entry(report, "synthetic.dcp")
        self.assertEqual(entry["read"]["status"], "passed")
        self.assertEqual(entry["compile"]["status"], "passed")
        self.assertEqual(entry["compile"]["readback"]["status"], "passed")
        self.assertEqual(entry["compile"]["output_format"], "rlook")
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse(list(self.root.glob(".rawlab-*")))

    def test_native_technical_cube_needs_no_compile_or_contract_warning(self):
        path = write_cube(self.root / "technical.cube")
        path.write_text("#Gamma:F-Log2C to F-Log2C\n#Gamut:F-GamutC to ITU-R BT.709\n" + path.read_text())
        report = audit_sources([self.root], verify_compile=True)
        entry = self.entry(report, "technical.cube")
        self.assertTrue(entry["metadata"]["native_photo_compatible"])
        self.assertFalse(entry["metadata"]["canonical"])
        self.assertEqual(entry["diagnostics"], [])
        self.assertEqual(entry["compile"]["status"], "not_run")
        self.assertIn("native CUBE import", entry["compile"]["reason"])

    def test_mixed_corpus_keeps_bad_entries_and_reports_xmp_structure(self):
        write_dcp(self.root / "valid.dcp")
        write_dcp(self.root / "missing-tone.dcp", omit=(50940,))
        (self.root / "corrupt.dcp").write_bytes(b"not a dcp")
        write_cube(self.root / "untagged.cube")
        write_xmp(self.root / "profile.xmp")
        compile_dcp(self.root / "valid.dcp", self.root / "compiled.rlook")
        (self.root / "ignored.txt").write_text("not a preset", encoding="utf-8")
        nested = self.root / "nested"
        nested.mkdir()
        write_dcp(nested / "nested.dcp")
        outside = self.root / "outside"
        outside.mkdir()
        write_dcp(outside / "outside.dcp")
        (self.root / "linked").symlink_to(outside, target_is_directory=True)

        report = audit_sources([self.root])
        paths = [entry["path"] for entry in report["entries"]]

        self.assertEqual(paths, sorted(paths))
        self.assertNotIn("ignored.txt", paths)
        self.assertNotIn("linked/outside.dcp", paths)
        self.assertIn("nested/nested.dcp", paths)
        self.assertEqual(self.entry(report, "valid.dcp")["read"]["status"], "passed")
        self.assertEqual(self.entry(report, "corrupt.dcp")["read"]["status"], "failed")
        missing = self.entry(report, "missing-tone.dcp")
        self.assertEqual(missing["read"]["status"], "failed")
        self.assertTrue(any("ProfileToneCurve" in value for value in missing["diagnostics"]))
        xmp = self.entry(report, "profile.xmp")
        self.assertEqual(xmp["format"], "xmp")
        self.assertEqual(xmp["read"]["status"], "passed")
        self.assertEqual(xmp["compile"]["status"], "not_run")
        self.assertTrue(any("dependency" in value.lower() for value in xmp["diagnostics"]))
        self.assertTrue(any("embedded" in value.lower() for value in xmp["diagnostics"]))
        self.assertEqual(self.entry(report, "untagged.cube")["read"]["status"], "passed")
        self.assertFalse(self.entry(report, "untagged.cube")["metadata"]["canonical"])
        self.assertEqual(self.entry(report, "compiled.rlook")["read"]["status"], "passed")
        for entry in report["entries"]:
            self.assertEqual(entry["appearance"]["status"], "unverified")

        verified = audit_sources([self.root], verify_compile=True)
        self.assertEqual(self.entry(verified, "profile.xmp")["compile"]["status"], "blocked")
        self.assertEqual(self.entry(verified, "missing-tone.dcp")["compile"]["status"], "blocked")

    def test_direct_unknown_file_gets_a_diagnostic(self):
        unknown = self.root / "preset.bin"
        unknown.write_bytes(b"unknown")

        report = audit_sources([unknown])

        self.assertEqual(len(report["entries"]), 1)
        entry = report["entries"][0]
        self.assertEqual(entry["path"], "preset.bin")
        self.assertEqual(entry["format"], "unknown")
        self.assertEqual(entry["read"]["status"], "failed")
        self.assertTrue(entry["diagnostics"])

    def test_cli_invalid_input_returns_two_with_json_body(self):
        missing = self.root / "missing"
        result = subprocess.run(
            [sys.executable, "-m", "lutools.lutprep", "audit", str(missing)],
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        body = json.loads(result.stdout)
        self.assertEqual(body["summary"]["status"], "failed")
        self.assertIn("missing", body["summary"]["diagnostics"][0])

    def test_scan_failure_is_reported_and_cli_returns_two(self):
        blocked = self.root / "blocked"
        blocked.mkdir()
        write_dcp(self.root / "visible.dcp")
        real_scandir = os.scandir

        def fail_blocked(path):
            if Path(path) == blocked:
                raise PermissionError("permission denied")
            return real_scandir(path)

        with patch.object(audit_module.os, "scandir", side_effect=fail_blocked):
            report = audit_sources([self.root])
            output = io.StringIO()
            with redirect_stdout(output):
                code = main(["audit", str(self.root)])

        self.assertEqual(report["summary"]["status"], "failed")
        self.assertEqual(report["summary"]["scan"]["status"], "failed")
        self.assertFalse(report["summary"]["complete"])
        self.assertTrue(any("blocked" in value for value in report["summary"]["scan"]["diagnostics"]))
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["summary"]["status"], "failed")

    def test_ocio_spi1d_and_clf_are_discovered_without_contract_guessing(self):
        write_spi1d(self.root / "identity.spi1d")
        write_clf(self.root / "identity.clf")

        report = audit_sources([self.root])

        spi1d = self.entry(report, "identity.spi1d")
        clf = self.entry(report, "identity.clf")
        self.assertEqual(spi1d["format"], "spi1d")
        self.assertEqual(spi1d["read"]["status"], "passed")
        self.assertFalse(spi1d["metadata"]["canonical"])
        self.assertTrue(any("contract" in value.lower() for value in spi1d["diagnostics"]))
        self.assertEqual(clf["format"], "clf")
        self.assertEqual(clf["read"]["status"], "passed")
        self.assertEqual(clf["compile"]["status"], "not_run")

    def test_xmp_table_payloads_are_bounded_and_crs_dependencies_are_scoped(self):
        write_xmp_tables(self.root / "tables.xmp")

        entry = self.entry(audit_sources([self.root]), "tables.xmp")
        metadata = entry["metadata"]
        payload = next(item for item in metadata["table_payloads"] if item["field"] == "Table_42")
        references = {item["field"]: item for item in metadata["table_references"]}

        self.assertEqual(payload["id"], "42")
        self.assertTrue(payload["present"])
        self.assertEqual(payload["bytes"], 2048)
        self.assertNotIn("data", payload)
        self.assertNotIn("A" * 512, json.dumps(metadata))
        self.assertEqual(references["LookTable"]["payload_status"], "present")
        self.assertEqual(references["RGBTable"]["payload_status"], "missing")
        dependency_fields = {item["field"] for item in metadata["dependencies"]}
        self.assertIn("LookTable", dependency_fields)
        self.assertNotIn("Profile", dependency_fields)

    def test_xmp_foreign_tables_are_unknown_and_nested_payload_is_not_leaked(self):
        write_xmp_namespace_and_nested_payload(self.root / "namespaces.xmp")

        entry = self.entry(audit_sources([self.root]), "namespaces.xmp")
        metadata = entry["metadata"]
        encoded = json.dumps(metadata)
        dependency_fields = {item["field"] for item in metadata["dependencies"]}
        table_fields = {item["field"] for item in metadata["table_payloads"]}
        reference_fields = {item["field"] for item in metadata["table_references"]}

        self.assertIn("Table_42", table_fields)
        self.assertNotIn("Table_7", table_fields)
        self.assertNotIn("LookTable", reference_fields)
        self.assertNotIn("RGBTable", reference_fields)
        self.assertNotIn("LookTable", dependency_fields)
        self.assertNotIn("RGBTable", dependency_fields)
        self.assertTrue({"Table_7", "LookTable", "RGBTable"}.issubset(
            set(metadata["unknown_fields"])))
        self.assertNotIn("SECRET_PAYLOAD", encoded)
        self.assertNotIn("FOREIGN_PAYLOAD", encoded)
        self.assertNotIn("FOREIGN_SECRET", encoded)

    def test_summary_completed_with_read_failure_and_independent_counters(self):
        (self.root / "broken.dcp").write_bytes(b"not a dcp")

        report = audit_sources([self.root], verify_compile=True)

        self.assertEqual(report["summary"]["status"], "completed")
        self.assertTrue(report["summary"]["complete"])
        self.assertEqual(report["summary"]["read_passed"], 0)
        self.assertEqual(report["summary"]["read_failed"], 1)
        self.assertEqual(report["summary"]["compile_blocked"], 1)
        self.assertEqual(report["summary"]["appearance_unverified"], 1)
        self.assertEqual(report["summary"]["scan"]["status"], "passed")

    def test_multiple_roots_have_non_absolute_identity_labels(self):
        left = self.root / "left"
        right = self.root / "right"
        left.mkdir()
        right.mkdir()
        write_dcp(left / "same.dcp")
        write_dcp(right / "same.dcp")

        report = audit_sources([left, right])

        self.assertEqual([item["path"] for item in report["entries"]], ["same.dcp", "same.dcp"])
        self.assertEqual({item["root"] for item in report["entries"]}, {"left", "right"})
        self.assertEqual({item["input_index"] for item in report["entries"]}, {0, 1})
        self.assertNotIn(str(self.root), json.dumps(report))


if __name__ == "__main__":
    unittest.main()
