import json
import os
from pathlib import Path
from typing import Any


BUNDLED_SNAPSHOT_PATH = Path(__file__).resolve().with_name("catalog_data.json")


def _discover_repo_shared() -> Path | None:
    env_repo = os.environ.get("RAWLAB_REPO")
    candidates: list[Path] = []
    if env_repo:
        candidates.append(Path(env_repo))
    # tools/mcp/src/rawlab_mcp/catalog.py -> repo root is 4 parents up.
    here = Path(__file__).resolve()
    if len(here.parents) >= 5:
        candidates.append(here.parents[4])
    for candidate in candidates:
        shared = candidate / "Shared"
        if (
            (shared / "master-recipes.json").is_file()
            and (shared / "BundledLooks" / "catalog.json").is_file()
            and (shared / "assets-manifest.json").is_file()
        ):
            return shared
    return None


def _derive_fuji_looks(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    fuji_looks: list[dict[str, Any]] = []
    files = manifest.get("groups", {}).get("luts", {}).get("files", [])
    for entry in files:
        rel = entry.get("path", "")
        if rel.startswith("lutools/flog-2-new/"):
            name = Path(rel).name
            if name.startswith("FLog2_to_") and "_65grid_" in name:
                short = name[len("FLog2_to_"):].split("_65grid_", 1)[0]
                fuji_looks.append({
                    "id": f"fuji:{short}",
                    "name": short,
                    "fileName": name,
                    "path": rel,
                    "sha256": entry.get("sha256"),
                    "grid": 65,
                })
        elif rel.startswith("lutools/F-Log2/"):
            name = Path(rel).name
            short = name
            if "_to_" in name and "_BT.709_" in name:
                short = name.split("_to_", 1)[1].split("_BT.709_", 1)[0]
            fuji_looks.append({
                "id": f"fuji33:{short}",
                "name": f"{short} (33)",
                "fileName": name,
                "path": rel,
                "sha256": entry.get("sha256"),
                "grid": 33,
            })
    return fuji_looks


def build_catalog(shared: Path) -> dict[str, Any]:
    """Derive the catalog from a repo `Shared/` dir; scripts/catalog/generate.py writes catalog_data.json from it."""
    master_recipes = json.loads((shared / "master-recipes.json").read_text(encoding="utf-8"))
    bundled_looks = json.loads((shared / "BundledLooks" / "catalog.json").read_text(encoding="utf-8"))
    manifest = json.loads((shared / "assets-manifest.json").read_text(encoding="utf-8"))
    hdr_dir = shared / "BundledLooks" / "HDR"
    hdr_looks: list[dict[str, Any]] = []
    for master_json in sorted(hdr_dir.glob("* Master.json")):
        payload = json.loads(master_json.read_text(encoding="utf-8"))
        look_val = payload.get("values", {}).get("hdr.look", {})
        look_name = look_val.get("name") or master_json.stem.removesuffix(" Master")
        cube_name = f"{look_name}.cube"
        hdr_looks.append({
            "id": f"hdr:{look_name}",
            "name": look_name,
            "fileName": cube_name,
            "path": f"Shared/BundledLooks/HDR/{cube_name}",
            "masterRecipePath": f"Shared/BundledLooks/HDR/{master_json.name}",
            "sha256": look_val.get("sha256"),
            "transferPreset": payload,
        })
    return {
        "master_recipes": master_recipes,
        "bundled_looks": bundled_looks,
        "fuji_flog2_looks": _derive_fuji_looks(manifest),
        "hdr_looks": hdr_looks,
    }


def load_catalog() -> dict[str, Any]:
    shared = _discover_repo_shared()
    if shared is not None:
        return {"source": "repo", **build_catalog(shared)}

    data = json.loads(BUNDLED_SNAPSHOT_PATH.read_text(encoding="utf-8"))
    return {"source": "bundled", **data}


def _find_on_disk(filename: str, read_roots: tuple[Path, ...]) -> str | None:
    if not filename:
        return None
    for root in read_roots:
        direct = root / filename
        if direct.is_file():
            resolved = Path(os.path.realpath(direct))
            if resolved == root or root in resolved.parents:
                return str(direct)
        for sub in (
            "Shared/BundledLooks",
            "Shared/BundledLooks/HDR",
            "RawLabMac/Resources/MasterRecipes",
            "lutools/flog-2-new",
            "lutools/F-Log2",
            "MasterRecipes",
            "LUTs",
        ):
            candidate = root / sub / filename
            if candidate.is_file():
                resolved = Path(os.path.realpath(candidate))
                if resolved == root or root in resolved.parents:
                    return str(candidate)
    return None


def list_looks(
    category: str = "all",
    query: str | None = None,
    read_roots: tuple[Path, ...] = (),
) -> dict[str, Any]:
    catalog = load_catalog()
    q = (query or "").strip().lower()

    def matches(entry: dict[str, Any], extra_fields: tuple[str, ...] = ()) -> bool:
        if not q:
            return True
        fields = [
            str(entry.get("id") or ""),
            str(entry.get("name") or ""),
            str(entry.get("fileName") or ""),
            str(entry.get("lutFileName") or ""),
            *(str(entry.get(k) or "") for k in extra_fields),
        ]
        return any(q in field.lower() for field in fields)

    items: list[dict[str, Any]] = []

    if category in ("all", "master_recipe"):
        for r in catalog["master_recipes"]:
            if not matches(r, ("subtitle", "summary")):
                continue
            fname = r.get("lutFileName", "")
            resolved = _find_on_disk(fname, read_roots)
            items.append({
                "category": "master_recipe",
                "id": r["id"],
                "name": r["name"],
                "subtitle": r.get("subtitle", ""),
                "summary": r.get("summary", ""),
                "file_name": fname,
                "look_reference": {"kind": "recipe", "id": r["id"]},
                "settings_version": r.get("settingsVersion", 4),
                "available_on_disk": resolved is not None,
                "resolved_path": resolved,
            })

    if category in ("all", "fuji_flog2"):
        for f in catalog["fuji_flog2_looks"]:
            if not matches(f, ("path",)):
                continue
            fname = f["fileName"]
            resolved = _find_on_disk(fname, read_roots)
            items.append({
                "category": "fuji_flog2",
                "id": f["id"],
                "name": f["name"],
                "file_name": fname,
                "repo_path": f["path"],
                "sha256": f.get("sha256"),
                "grid": f.get("grid"),
                "look_reference": {"kind": "builtin", "id": fname},
                "available_on_disk": resolved is not None,
                "resolved_path": resolved,
            })

    if category in ("all", "bundled"):
        for b in catalog["bundled_looks"]:
            if not matches(b, ("artworkName", "input", "output")):
                continue
            fname = b["fileName"]
            resolved = _find_on_disk(fname, read_roots)
            items.append({
                "category": "bundled",
                "id": b["id"],
                "name": b["name"],
                "file_name": fname,
                "sha256": b.get("sha256"),
                "input_space": b.get("input"),
                "output_space": b.get("output"),
                "license": b.get("license"),
                "look_reference": {"kind": "builtin", "id": fname},
                "available_on_disk": resolved is not None,
                "resolved_path": resolved,
            })

    if category in ("all", "hdr"):
        for h in catalog["hdr_looks"]:
            if not matches(h, ("path",)):
                continue
            fname = h["fileName"]
            resolved = _find_on_disk(fname, read_roots)
            items.append({
                "category": "hdr",
                "id": h["id"],
                "name": h["name"],
                "file_name": fname,
                "sha256": h.get("sha256"),
                "transfer_preset": h.get("transferPreset"),
                "available_on_disk": resolved is not None,
                "resolved_path": resolved,
            })

    counts: dict[str, int] = {}
    for entry in items:
        cat = entry["category"]
        counts[cat] = counts.get(cat, 0) + 1

    return {
        "source": catalog["source"],
        "category": category,
        "query": query,
        "total_count": len(items),
        "counts": counts,
        "looks": items,
    }
