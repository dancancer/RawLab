"""Read-only source inventory and compilation diagnostics for preset files."""

from collections import Counter
import os
from pathlib import Path
import re
import tempfile
from xml.etree import ElementTree

from .bake import inspect_source
from .dcp import DCPProfile
from .native import compile_dcp, read_native


SCHEMA_VERSION = 1
OCIO_SUFFIXES = frozenset({
    ".cube", ".spi1d", ".spi3d", ".clf", ".ctf", ".3dl", ".lut",
    ".csp", ".cc", ".ccc", ".cdl",
})
KNOWN_SUFFIXES = frozenset({".dcp", ".rlook", ".xmp", *OCIO_SUFFIXES})
OCIO_FORMATS = frozenset(suffix[1:] for suffix in OCIO_SUFFIXES)
KNOWN_FORMATS = frozenset(suffix[1:] for suffix in KNOWN_SUFFIXES)
MAX_XMP_BYTES = 16 * 1024 * 1024
CRS_NAMESPACE = "http://ns.adobe.com/camera-raw-settings/1.0/"
_TABLE_PAYLOAD = re.compile(r"^table_(.+)$", re.IGNORECASE)
_TABLE_REFERENCES = frozenset({"rgbtable", "looktable"})


class AuditInputError(ValueError):
    """Raised when an audit input cannot be treated as a file or directory."""


def _error_text(error, path=None):
    text = str(error).strip()
    if path is not None:
        try:
            source = Path(path)
            text = text.replace(str(source.resolve()), source.name)
            text = text.replace(str(source.parent.resolve()), ".")
        except OSError:
            pass
    return text or error.__class__.__name__


def _local_name(tag):
    if not isinstance(tag, str):
        return ""
    return tag.rsplit("}", 1)[-1].split(":", 1)[-1]


def _namespace(tag):
    if isinstance(tag, str) and tag.startswith("{") and "}" in tag:
        return tag[1:].split("}", 1)[0]
    return ""


def _safe_value(value, *, limit=2048):
    if isinstance(value, str):
        if os.path.isabs(value):
            value = Path(value).name or "<absolute path>"
        return value if len(value) <= limit else value[:limit] + "..."
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    if isinstance(value, (list, tuple)):
        return [_safe_value(item, limit=limit) for item in value]
    if isinstance(value, dict):
        return {str(key): _safe_value(item, limit=limit) for key, item in value.items()}
    return str(value)


def _inspect_dcp(path):
    profile = DCPProfile.read(path)
    return profile.describe(), []


def _inspect_rlook(path):
    parsed = read_native(path)
    metadata = _safe_value(parsed["metadata"])
    return metadata, []


def _inspect_cube(path):
    info = inspect_source(path)
    metadata = {key: _safe_value(value) for key, value in info.items() if key != "source"}
    diagnostics = []
    if not metadata.get("native_photo_compatible", False):
        diagnostics.append("CUBE has no recognized RawLab color contract; contract is required before preparation")
    return metadata, diagnostics


def _inspect_ocio(path, fmt):
    info = inspect_source(path)
    metadata = {key: _safe_value(value) for key, value in info.items() if key != "source"}
    metadata.setdefault("format", fmt)
    metadata.setdefault("canonical", False)
    diagnostics = []
    if not metadata.get("canonical", False):
        diagnostics.append("OCIO source has no recognized RawLab color contract; contract is required before preparation")
    return metadata, diagnostics


_KNOWN_XMP_FIELDS = frozenset({
    "amount", "blackpoint", "blacks", "camera", "cameraprofile", "clarity",
    "contrast", "defringe", "dehaze", "exposure", "grainamount", "highlights",
    "lensprofileenable", "look", "lookamount", "looktable", "looktablename",
    "looktabledims", "processversion", "profile", "profileamount", "profilename",
    "rgbtable",
    "saturation", "shadows", "sharpness", "temperature", "tint", "version",
    "vibrance", "whites",
})


def _xmp_field_value(value):
    if value is None:
        return ""
    value = " ".join(str(value).split())
    if os.path.isabs(value):
        value = Path(value).name or "<absolute path>"
    return value if len(value) <= 512 else value[:512] + "..."


def _table_reference_id(value):
    value = " ".join(str(value or "").split())
    if not value or len(value) > 256:
        return None
    match = re.fullmatch(r"(?:table[_:])?([A-Za-z0-9][A-Za-z0-9_.-]*)", value, re.IGNORECASE)
    return match.group(1) if match else None


def _inspect_xmp(path):
    if path.stat().st_size > MAX_XMP_BYTES:
        raise ValueError(f"XMP exceeds the {MAX_XMP_BYTES // (1024 * 1024)} MiB audit limit")
    root = ElementTree.parse(path).getroot()
    fields = {}
    dependencies = []
    table_payloads = []
    table_references = []
    unknown_fields = set()
    namespaces = set()

    def record_field(name, value, *, namespace, source):
        name = _local_name(name)
        if not name:
            return
        lowered = name.lower()
        payload_match = _TABLE_PAYLOAD.fullmatch(name)
        if payload_match:
            raw = "" if value is None else str(value)
            payload = {"field": name, "id": payload_match.group(1),
                       "present": bool(raw), "bytes": len(raw.encode("utf-8"))}
            if namespace == CRS_NAMESPACE:
                table_payloads.append(payload)
            else:
                fields.setdefault(name, []).append(dict(payload))
                unknown_fields.add(name)
            if namespace == CRS_NAMESPACE:
                fields.setdefault(name, []).append(dict(payload))
            return

        if lowered in _TABLE_REFERENCES:
            reference = {"field": name, "id": _table_reference_id(value)}
            if namespace == CRS_NAMESPACE:
                table_references.append(reference)
                fields.setdefault(name, []).append(dict(reference))
            else:
                reference["payload_status"] = "unknown"
                fields.setdefault(name, []).append(dict(reference))
                unknown_fields.add(name)
        else:
            fields.setdefault(name, []).append(_xmp_field_value(value))

        value = _xmp_field_value(value)
        if namespace == CRS_NAMESPACE and (
                lowered in _TABLE_REFERENCES or
                any(token in lowered for token in ("profile", "camera", "dependency", "base"))):
            dependencies.append({"field": name, "value": value, "source": source})
        if (lowered not in _KNOWN_XMP_FIELDS or
                (namespace != CRS_NAMESPACE and (
                    lowered in _TABLE_REFERENCES or
                    any(token in lowered for token in ("profile", "camera", "dependency", "base"))))):
            unknown_fields.add(name)

    table_elements = {}
    for candidate in root.iter():
        candidate_name = _local_name(candidate.tag)
        if _TABLE_PAYLOAD.fullmatch(candidate_name):
            table_elements[id(candidate)] = candidate
    nested_payload_elements = set()
    for node in table_elements.values():
        nested_payload_elements.update(id(element) for element in node.iter() if element is not node)

    for element in root.iter():
        if id(element) in nested_payload_elements:
            continue
        namespace = _namespace(element.tag)
        if namespace:
            namespaces.add(namespace)
        name = _local_name(element.tag)
        if id(element) in table_elements:
            record_field(name, "".join(element.itertext()), namespace=namespace, source="element")
            continue
        if name and name.lower() not in {"xmpmeta", "rdf", "description", "li", "seq", "bag", "alt"}:
            has_value = bool(element.text and element.text.strip())
            if has_value or name.lower() in _TABLE_REFERENCES:
                record_field(name, element.text, namespace=namespace, source="element")
        for attribute, value in element.attrib.items():
            namespace = _namespace(attribute)
            if namespace:
                namespaces.add(namespace)
            record_field(attribute, value, namespace=namespace, source="attribute")

    payload_ids = {item["id"].casefold() for item in table_payloads if item["present"]}
    for reference in table_references:
        identifier = reference["id"]
        reference["payload_status"] = (
            "present" if identifier and identifier.casefold() in payload_ids else "missing"
        )

    metadata = {
        "xml": {"root": _local_name(root.tag), "namespaces": sorted(namespaces)},
        "fields": fields,
        "dependencies": dependencies,
        "table_payloads": table_payloads,
        "table_references": table_references,
        "embedded_tables": [*table_payloads, *table_references],
        "unknown_fields": sorted(unknown_fields),
    }
    diagnostics = ["XMP XML structure parsed; execution is not implemented"]
    if dependencies:
        diagnostics.append("XMP dependency requirements recorded: " + ", ".join(
            sorted({item["field"] for item in dependencies})))
    else:
        diagnostics.append("XMP dependency requirements: none declared")
    if table_payloads or table_references:
        diagnostics.append("XMP embedded-table references recorded: " + ", ".join(
            sorted({item["field"] for item in [*table_payloads, *table_references]})))
    else:
        diagnostics.append("XMP embedded-table references: none declared")
    if unknown_fields:
        diagnostics.append("XMP unknown fields recorded: " + ", ".join(sorted(unknown_fields)))
    return metadata, diagnostics


def _inspect_file(path, fmt):
    if fmt == "dcp":
        return _inspect_dcp(path)
    if fmt == "rlook":
        return _inspect_rlook(path)
    if fmt == "cube":
        return _inspect_cube(path)
    if fmt == "xmp":
        return _inspect_xmp(path)
    if fmt in OCIO_FORMATS:
        return _inspect_ocio(path, fmt)
    raise ValueError("Unsupported preset format; expected .cube, .dcp, .rlook or .xmp")


def _is_policy_blocker(text):
    lowered = text.lower()
    return any(token in lowered for token in (
        "profiletonecurve", "tone-curve", "tone curve", "auto black", "black rendering policy",
    ))


def _compile_status(path, fmt, read_status, diagnostics, metadata, verify_compile):
    if not verify_compile:
        return {"status": "not_run"}
    if fmt == "xmp":
        return {"status": "blocked", "reason": "XMP execution and compilation are not implemented"}
    if read_status != "passed":
        reason = "Source read failed; compilation was not attempted"
        if any(_is_policy_blocker(item) for item in diagnostics):
            reason = "DCP compilation blocked by an explicit source policy requirement"
        return {"status": "blocked", "reason": reason}
    if fmt == "dcp":
        with tempfile.TemporaryDirectory(prefix="rawlab-audit-") as directory:
            output = Path(directory) / (path.stem + ".rlook")
            try:
                report = compile_dcp(path, output)
                readback = read_native(output)
            except Exception as error:  # A corrupt source must not suppress the other entries.
                text = _error_text(error, path)
                return {"status": "blocked" if _is_policy_blocker(text) else "failed",
                        "reason": text}
            readback_metadata = _safe_value(readback["metadata"])
            return {"status": "passed", "output_format": "rlook",
                    "format_version": readback_metadata.get("format_version"),
                    "report": _safe_value(report),
                    "readback": {"status": "passed", "metadata": readback_metadata}}
    if fmt == "rlook":
        return {"status": "not_run", "reason": "Source is already a compiled RLOOK"}
    if fmt == "cube":
        if metadata.get("canonical", False):
            return {"status": "not_run", "reason": "Source is already a canonical CUBE"}
        if metadata.get("native_photo_compatible", False):
            return {"status": "not_run", "reason": "Source supports direct native CUBE import; no compilation is required"}
        return {"status": "blocked", "reason": "CUBE has no declared RawLab color contract"}
    if fmt in OCIO_FORMATS:
        return {"status": "blocked", "reason": "OCIO source has no declared RawLab color contract"}
    return {"status": "blocked", "reason": "Unknown source format cannot be compiled"}


def _audit_entry(path, relative_path, verify_compile, input_index, root_label):
    suffix = path.suffix.lower()
    fmt = suffix[1:] if suffix else "unknown"
    if fmt not in KNOWN_FORMATS:
        fmt = "unknown"
    metadata, diagnostics = {}, []
    read = {"status": "failed"}
    try:
        metadata, diagnostics = _inspect_file(path, fmt)
        read = {"status": "passed"}
    except Exception as error:  # Keep one bad file from suppressing the rest of a corpus.
        diagnostics = [_error_text(error, path)]
    entry = {
        "path": relative_path,
        "root": root_label,
        "input_index": input_index,
        "format": fmt,
        "metadata": _safe_value(metadata),
        "diagnostics": [_safe_value(item) for item in diagnostics],
        "read": read,
        "compile": _compile_status(path, fmt, read["status"], diagnostics, metadata, verify_compile),
        "appearance": {
            "status": "unverified",
            "reason": "No independent appearance reference was supplied",
        },
    }
    return entry


def _walk_known_files(root):
    files = []
    diagnostics = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            try:
                relative = Path(directory).relative_to(root).as_posix()
            except ValueError:
                relative = Path(directory).name
            diagnostics.append(f"Unable to scan directory {relative or '.'}: {_error_text(error)}")
            continue
        for child in children:
            child_path = Path(child.path)
            try:
                if child.is_symlink():
                    continue
                if child.is_dir(follow_symlinks=False):
                    pending.append(child_path)
                elif child.is_file(follow_symlinks=False) and child_path.suffix.lower() in KNOWN_SUFFIXES:
                    files.append(child_path)
            except OSError as error:
                try:
                    relative = child_path.relative_to(root).as_posix()
                except ValueError:
                    relative = child_path.name
                diagnostics.append(f"Unable to inspect directory entry {relative}: {_error_text(error)}")
    return files, diagnostics


def _invalid_input(path, reason):
    label = Path(path).name or str(path)
    raise AuditInputError(f"Input path {label!r} is invalid: {reason}")


def audit_sources(paths, verify_compile=False):
    """Return a deterministic, read-only report for the supplied preset paths."""
    if isinstance(paths, (str, Path)):
        paths = [paths]
    paths = list(paths)
    if not paths:
        raise AuditInputError("Audit requires at least one input path")

    sources = []
    scan_diagnostics = []
    for input_index, supplied in enumerate(paths):
        path = Path(supplied)
        if not path.exists():
            _invalid_input(path, "does not exist")
        if path.is_dir():
            if path.is_symlink():
                _invalid_input(path, "directory symlinks are not followed")
            root = path
            candidates, diagnostics = _walk_known_files(path)
            root_label = path.name or f"input-{input_index}"
            scan_diagnostics.extend(f"{root_label}: {value}" for value in diagnostics)
        elif path.is_file():
            root = path.parent
            candidates = [path]
            root_label = root.name or f"input-{input_index}"
        else:
            _invalid_input(path, "not a regular file or directory")
        for candidate in candidates:
            relative = candidate.relative_to(root).as_posix()
            sources.append((input_index, root_label, relative, candidate))

    sources.sort(key=lambda item: (item[0], item[2], str(item[3])))
    entries = [_audit_entry(path, relative, bool(verify_compile), input_index, root_label)
               for input_index, root_label, relative, path in sources]
    counters = Counter(entry["read"]["status"] for entry in entries)
    compile_counters = Counter(entry["compile"]["status"] for entry in entries)
    appearance_counters = Counter(entry["appearance"]["status"] for entry in entries)
    scan_status = "failed" if scan_diagnostics else "passed"
    summary = {
        "status": "failed" if scan_diagnostics else "completed",
        "complete": not scan_diagnostics,
        "total": len(entries),
        "read_passed": counters.get("passed", 0),
        "read_failed": counters.get("failed", 0),
        "compile_not_run": compile_counters.get("not_run", 0),
        "compile_passed": compile_counters.get("passed", 0),
        "compile_blocked": compile_counters.get("blocked", 0),
        "compile_failed": compile_counters.get("failed", 0),
        "appearance_unverified": appearance_counters.get("unverified", 0),
        "scan": {"status": scan_status, "diagnostics": scan_diagnostics},
        "scan_failed": len(scan_diagnostics),
        "diagnostics": list(scan_diagnostics),
    }
    return {"version": SCHEMA_VERSION, "entries": entries, "summary": summary}


def invalid_report(error):
    """Build the JSON body used by the CLI for invalid top-level inputs."""
    return {"version": SCHEMA_VERSION, "entries": [],
            "summary": {"status": "failed", "complete": False, "total": 0,
                        "scan": {"status": "failed", "diagnostics": [_error_text(error)]},
                        "scan_failed": 1, "diagnostics": [_error_text(error)]}}
