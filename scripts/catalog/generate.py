#!/usr/bin/env python3
"""Generate the MCP bundled looks catalog snapshot from Shared/; --check verifies freshness.

The snapshot is what rawlab_mcp.catalog serves when it runs outside the repo. It is derived by the
same rawlab_mcp.catalog.build_catalog() the server uses in repo mode, from Shared/master-recipes.json,
Shared/BundledLooks/catalog.json, Shared/assets-manifest.json and Shared/BundledLooks/HDR/* Master.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]
SNAPSHOT_REL = "tools/mcp/src/rawlab_mcp/catalog_data.json"

sys.path.insert(0, str(ROOT / "tools/mcp/src"))
from rawlab_mcp.catalog import build_catalog  # noqa: E402


def render(root: Path) -> str:
    return json.dumps(build_catalog(root / "Shared"), indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare the snapshot without writing")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        text = render(args.root)
        path = args.root / SNAPSHOT_REL
        if args.check:
            if not path.is_file() or path.read_bytes() != text.encode("utf-8"):
                print(f"Generated catalog differs: {SNAPSHOT_REL}", file=sys.stderr)
                return 1
            print(f"Checked {SNAPSHOT_REL} against Shared/: byte-identical")
            return 0
        path.write_bytes(text.encode("utf-8"))
        print(f"Generated {SNAPSHOT_REL} from Shared/")
        return 0
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print(f"Catalog generation error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
