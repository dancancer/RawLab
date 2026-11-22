"""Anti-drift check for bundled rawlab_mcp JSON snapshots without repo shadowing."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class McpBundledSnapshotsTests(unittest.TestCase):
    def test_bundled_transfer_spec_and_catalog_match_repo_without_shadowing(self) -> None:
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

        with tempfile.TemporaryDirectory(prefix="rawlab-ci-mcp-snap-") as tmp:
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
                "assert gui_sync._discover_repo_spec_path() is None\n"
                "assert catalog._discover_repo_shared() is None\n"
                "print(json.dumps({'fields': gui_sync._TRANSFER_FIELDS, 'catalog': catalog.load_catalog()}))\n"
            )
            loaded = json.loads(subprocess.check_output([sys.executable, "-c", probe], cwd=tmp, env=env, text=True))

        self.assertEqual(loaded["fields"], expected_fields)
        repo_master = json.loads((ROOT / "Shared/master-recipes.json").read_text(encoding="utf-8"))
        repo_bundled = json.loads((ROOT / "Shared/BundledLooks/catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(loaded["catalog"]["master_recipes"], repo_master)
        self.assertEqual(loaded["catalog"]["bundled_looks"], repo_bundled)


if __name__ == "__main__":
    unittest.main()
