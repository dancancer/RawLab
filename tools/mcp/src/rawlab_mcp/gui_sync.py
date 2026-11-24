from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Any, Awaitable, Callable

from .errors import AdapterError


BUNDLED_TRANSFER_SPEC_PATH = Path(__file__).resolve().with_name("transfer_spec.json")


def _discover_repo_spec_path() -> Path | None:
    env_repo = os.environ.get("RAWLAB_REPO")
    candidates: list[Path] = []
    if env_repo:
        candidates.append(Path(env_repo))
    here = Path(__file__).resolve()
    if len(here.parents) >= 5:
        candidates.append(here.parents[4])
    for candidate in candidates:
        spec_file = candidate / "Shared" / "specs" / "adjustment-fields-v1.json"
        if spec_file.is_file():
            return spec_file
    return None


def _load_transfer_spec() -> dict[str, dict[str, Any]]:
    repo_spec = _discover_repo_spec_path()
    if repo_spec is not None:
        raw = json.loads(repo_spec.read_text(encoding="utf-8"))
        fields: dict[str, dict[str, Any]] = {}
        for entry in raw.get("fields", []):
            proto = entry.get("protocol", {})
            if proto.get("transferable"):
                fields[entry["field_id"]] = {
                    "value_type": proto["value_type"],
                    "nullable": bool(proto["nullable"]),
                    "min": proto["min"],
                    "max": proto["max"],
                    "exclusive_min": bool(proto.get("exclusive_min", False)),
                    "exclusive_max": bool(proto.get("exclusive_max", False)),
                    "non_empty": bool(proto.get("non_empty", False)),
                    "allowed_values": proto.get("allowed_values"),
                    "object_keys": proto.get("object_keys"),
                    "optional_keys": proto.get("optional_keys"),
                    "hdr_only": bool(proto.get("hdr_only", False)),
                    "sub_fields": proto.get("sub_fields"),
                }
        return fields
    bundled = json.loads(BUNDLED_TRANSFER_SPEC_PATH.read_text(encoding="utf-8"))
    return bundled["fields"]


_TRANSFER_FIELDS: dict[str, dict[str, Any]] = _load_transfer_spec()


def resolve_controlled_subpath(data_dir: Path, subdir: str, filename: str) -> Path:
    if not subdir or "/" in subdir or "\\" in subdir or subdir in (".", ".."):
        raise AdapterError("Invalid controlled subdirectory")
    if not filename or "/" in filename or "\\" in filename or filename in (".", ".."):
        raise AdapterError("Invalid controlled filename")

    canonical_root = Path(os.path.realpath(data_dir))
    if canonical_root.exists() and not canonical_root.is_dir():
        raise AdapterError("Controlled data_dir must be a directory")

    target_dir = canonical_root / subdir
    if os.path.lexists(target_dir):
        if target_dir.is_symlink():
            raise AdapterError(f"Controlled directory '{subdir}' cannot be a symbolic link")
        if not target_dir.is_dir():
            raise AdapterError(f"Controlled directory '{subdir}' is not a directory")
        if Path(os.path.realpath(target_dir)) != canonical_root / subdir:
            raise AdapterError(f"Controlled directory '{subdir}' escaped data_dir")

    target_file = target_dir / filename
    if os.path.lexists(target_file):
        if target_file.is_symlink():
            raise AdapterError(f"Controlled store '{filename}' cannot be a symbolic link")
        if not target_file.is_file():
            raise AdapterError(f"Controlled store '{filename}' is not a regular file")
        if Path(os.path.realpath(target_file)) != canonical_root / subdir / filename:
            raise AdapterError(f"Controlled store '{filename}' escaped data_dir")

    return target_file


def _build_save_preset_request(
    *,
    data_dir: Path,
    name: str,
    values: dict[str, Any],
    is_raw: bool | None = None,
    processing_version: int = 3,
    overwrite: bool = False,
    recipe_context: dict[str, Any] | None = None,
    hdr_processing_version: int | None = None,
) -> dict[str, Any]:
    resolve_controlled_subpath(data_dir, "Presets", "presets.json")
    lock_name = "presets.json.lock" if os.name == "nt" else ".presets.lock"
    resolve_controlled_subpath(data_dir, "Presets", lock_name)
    return {
        "data_dir": str(data_dir),
        "name": name,
        "values": values,
        "is_raw": is_raw,
        "processing_version": processing_version,
        "overwrite": overwrite,
        "recipe_context": recipe_context,
        "hdr_processing_version": hdr_processing_version,
    }


def _build_sync_photo_edit_request(
    *,
    data_dir: Path,
    photo_canonical: Path,
    adjustments: dict[str, Any],
    is_raster: bool,
    film_id: str = "",
    master_recipe_id: str | None = None,
) -> dict[str, Any]:
    resolve_controlled_subpath(data_dir, "Edits", "edits.json")
    lock_name = "edits.json.lock" if os.name == "nt" else ".edits.lock"
    resolve_controlled_subpath(data_dir, "Edits", lock_name)
    return {
        "data_dir": str(data_dir),
        "photo_path": str(photo_canonical),
        "adjustments": adjustments,
        "is_raster": bool(is_raster),
        "film_id": film_id,
        "master_recipe_id": master_recipe_id,
    }


def _encode_request_json(payload: dict[str, Any]) -> str:
    try:
        return json.dumps(payload, ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError) as e:
        raise AdapterError(f"Invalid request payload: {e}") from e


def _unwrap_envelope(envelope: Any) -> dict[str, Any]:
    if isinstance(envelope, dict):
        if envelope.get("ok"):
            result = envelope.get("result")
            if isinstance(result, dict):
                return result
            raise AdapterError("CLI returned malformed result", "processing_error")
        err = envelope.get("error") or {}
        raise AdapterError(
            str(err.get("message") or "CLI store error"),
            str(err.get("code") or "processing_error"),
            err.get("status"),
        )
    if getattr(envelope, "ok", False):
        result = getattr(envelope, "result", None)
        if isinstance(result, dict):
            return result
        raise AdapterError("CLI returned malformed result", "processing_error")
    err_obj = getattr(envelope, "error", None)
    if err_obj is not None:
        raise AdapterError(err_obj.message, err_obj.code, err_obj.status)
    raise AdapterError("CLI returned unknown error", "processing_error")


def _resolve_default_cli() -> str:
    env_cli = os.environ.get("RAWLAB_MCP_CLI")
    if env_cli:
        raw_path = Path(env_cli)
        if not raw_path.is_absolute():
            raise AdapterError("RAWLAB_MCP_CLI must be an absolute path", "processing_error")
    else:
        found = shutil.which("sony2fuji.exe" if os.name == "nt" else "sony2fuji")
        if not found:
            raise AdapterError(
                "sony2fuji CLI executable not found; set RAWLAB_MCP_CLI or pass cli_runner",
                "processing_error",
            )
        raw_path = Path(found)
    try:
        cli_path = raw_path.resolve(strict=True)
    except OSError as e:
        raise AdapterError(f"Could not resolve CLI: {e}", "processing_error") from e
    if not cli_path.is_file() or not os.access(cli_path, os.X_OK):
        raise AdapterError("CLI must be an executable file", "processing_error")
    return str(cli_path)


def _default_cli_runner(command: str, args: list[str]) -> dict[str, Any]:
    cli_path = _resolve_default_cli()
    try:
        proc = subprocess.run(
            [cli_path, *args],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        raise AdapterError(f"CLI {command} timed out", "processing_error") from e
    except OSError as e:
        raise AdapterError(f"Could not execute CLI {command}: {e}", "processing_error") from e
    stdout = (proc.stdout or "").strip()
    if not stdout:
        msg = (proc.stderr or "").strip() or f"CLI {command} exited with status {proc.returncode}"
        raise AdapterError(msg, "processing_error", proc.returncode or None)
    try:
        data = json.loads(stdout.splitlines()[-1])
    except ValueError as e:
        raise AdapterError(f"CLI {command} returned invalid JSON: {e}", "processing_error") from e
    if isinstance(data, dict) and "ok" in data:
        return data
    raise AdapterError(f"CLI {command} returned unexpected response", "processing_error")


async def save_preset_async(
    *,
    data_dir: Path,
    name: str,
    values: dict[str, Any],
    is_raw: bool | None = None,
    processing_version: int = 3,
    overwrite: bool = False,
    recipe_context: dict[str, Any] | None = None,
    hdr_processing_version: int | None = None,
    cli_runner: Callable[[str, list[str]], Awaitable[Any]],
) -> dict[str, Any]:
    payload = _build_save_preset_request(
        data_dir=data_dir,
        name=name,
        values=values,
        is_raw=is_raw,
        processing_version=processing_version,
        overwrite=overwrite,
        recipe_context=recipe_context,
        hdr_processing_version=hdr_processing_version,
    )
    encoded = _encode_request_json(payload)
    with tempfile.TemporaryDirectory(prefix="rawlab-mcp-preset-") as tmp_dir:
        req_file = Path(tmp_dir) / "request.json"
        req_file.write_text(encoded, encoding="utf-8")
        envelope = await cli_runner("save_preset", ["--save-preset", "--request", str(req_file), "--json"])
    return _unwrap_envelope(envelope)


async def sync_photo_edit_async(
    *,
    data_dir: Path,
    photo_canonical: Path,
    adjustments: dict[str, Any],
    is_raster: bool,
    film_id: str = "",
    master_recipe_id: str | None = None,
    cli_runner: Callable[[str, list[str]], Awaitable[Any]],
) -> dict[str, Any]:
    payload = _build_sync_photo_edit_request(
        data_dir=data_dir,
        photo_canonical=photo_canonical,
        adjustments=adjustments,
        is_raster=is_raster,
        film_id=film_id,
        master_recipe_id=master_recipe_id,
    )
    encoded = _encode_request_json(payload)
    with tempfile.TemporaryDirectory(prefix="rawlab-mcp-sync-") as tmp_dir:
        req_file = Path(tmp_dir) / "request.json"
        req_file.write_text(encoded, encoding="utf-8")
        envelope = await cli_runner("sync_photo_edit", ["--sync-photo-edit", "--request", str(req_file), "--json"])
    return _unwrap_envelope(envelope)


def save_preset(
    *,
    data_dir: Path,
    name: str,
    values: dict[str, Any],
    is_raw: bool | None = None,
    processing_version: int = 3,
    overwrite: bool = False,
    recipe_context: dict[str, Any] | None = None,
    hdr_processing_version: int | None = None,
    cli_runner: Callable[[str, list[str]], Any] | None = None,
) -> dict[str, Any]:
    payload = _build_save_preset_request(
        data_dir=data_dir,
        name=name,
        values=values,
        is_raw=is_raw,
        processing_version=processing_version,
        overwrite=overwrite,
        recipe_context=recipe_context,
        hdr_processing_version=hdr_processing_version,
    )
    encoded = _encode_request_json(payload)
    runner = cli_runner or _default_cli_runner
    with tempfile.TemporaryDirectory(prefix="rawlab-mcp-preset-") as tmp_dir:
        req_file = Path(tmp_dir) / "request.json"
        req_file.write_text(encoded, encoding="utf-8")
        envelope = runner("save_preset", ["--save-preset", "--request", str(req_file), "--json"])
    return _unwrap_envelope(envelope)


def sync_photo_edit(
    *,
    data_dir: Path,
    photo_canonical: Path,
    adjustments: dict[str, Any],
    is_raster: bool,
    film_id: str = "",
    master_recipe_id: str | None = None,
    cli_runner: Callable[[str, list[str]], Any] | None = None,
) -> dict[str, Any]:
    payload = _build_sync_photo_edit_request(
        data_dir=data_dir,
        photo_canonical=photo_canonical,
        adjustments=adjustments,
        is_raster=is_raster,
        film_id=film_id,
        master_recipe_id=master_recipe_id,
    )
    encoded = _encode_request_json(payload)
    runner = cli_runner or _default_cli_runner
    with tempfile.TemporaryDirectory(prefix="rawlab-mcp-sync-") as tmp_dir:
        req_file = Path(tmp_dir) / "request.json"
        req_file.write_text(encoded, encoding="utf-8")
        envelope = runner("sync_photo_edit", ["--sync-photo-edit", "--request", str(req_file), "--json"])
    return _unwrap_envelope(envelope)
