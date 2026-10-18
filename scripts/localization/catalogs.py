"""读取唯一来源并验证词条归属。"""

import json
from collections import defaultdict

from formats import PRINTF, normalize, render

LANGUAGES = ("zh-Hans", "en", "de", "fr", "ja", "es")
CLIENTS = ("macos", "ios", "windows", "android")
ANDROID_DIRS = dict(zip(LANGUAGES, (
    "values-b+zh+Hans", "values", "values-de", "values-fr", "values-ja", "values-es",
)))


# ---- 来源验证 ----

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_pairs)


def load(root):
    directory = root / "Shared/strings"
    shared = read_json(directory / "common/catalog.json")
    platforms = {client: read_json(directory / "platforms" / (client + ".json")) for client in CLIENTS}
    usage = defaultdict(set)
    for client, platform in platforms.items():
        validate_platform(client, platform, shared, usage)
    expected = {key for key, clients in usage.items() if len(clients) > 1}
    if set(shared) != expected:
        raise ValueError("Shared entries must be used by at least two platforms; no unowned entries")
    validate_values(shared)
    return shared, platforms


def validate_values(catalog):
    for key, values in catalog.items():
        if set(values) != set(LANGUAGES):
            raise ValueError(f"Missing or unexpected languages: {key}")
        if not all(isinstance(value, str) and value.strip() for value in values.values()):
            raise ValueError(f"Empty or invalid translation: {key}")


def validate_platform(client, platform, shared, usage):
    if set(platform) != {"entries", "unique", "overrides"}:
        raise ValueError(f"Unexpected platform fields: {client}")
    unique, overrides = platform["unique"], platform["overrides"]
    validate_values(unique)
    if set(unique) & set(shared) or not set(overrides) <= set(shared):
        raise ValueError(f"Invalid unique/override ownership: {client}")
    for override in overrides.values():
        if set(override) != {"reason", "values"} or not override["reason"].strip():
            raise ValueError(f"Overrides require a platform-specific reason: {client}")
        validate_values({"override": override["values"]})
    sources = {entry["source"] for entry in platform["entries"].values()}
    if set(unique) != sources - set(shared) or not set(overrides) <= sources:
        raise ValueError(f"Unowned platform entries: {client}")
    for key, entry in platform["entries"].items():
        usage[entry["source"]].add(client)
        validate_entry(client, key, entry)
        for language in LANGUAGES:
            translated(shared, platform, entry, language, client)


def validate_entry(client, key, entry):
    fields = {"source", "formats"}
    if client == "android":
        fields |= {"file", "types"}
    if set(entry) != fields:
        raise ValueError(f"Unexpected mapping fields: {client}/{key}")
    style = client if client in ("windows", "android") else "apple"
    render(entry["source"], entry["formats"], style)
    if client != "android":
        if normalize(key, style) != (entry["source"], entry["formats"]):
            raise ValueError(f"Native key mapping mismatch: {client}/{key}")
        return
    if entry["file"] not in ("strings.xml", "editor_strings.xml"):
        raise ValueError(f"Unknown Android resource file: {key}")
    types = [token[-1] for token in entry["formats"]]
    if types != entry["types"] or not set(types) <= {"d", "s", "f"}:
        raise ValueError(f"Android argument types mismatch: {key}")
    for index, token in enumerate(entry["formats"]):
        match = PRINTF.fullmatch(token)
        if not match or match[1] != str(index + 1):
            raise ValueError(f"Android arguments must be positional: {key}")


def translated(shared, platform, entry, language, client):
    source = entry["source"]
    values = platform["overrides"].get(source, {}).get("values")
    if values is None:
        values = shared[source] if source in shared else platform["unique"][source]
    style = client if client in ("windows", "android") else "apple"
    return render(values[language], entry["formats"], style)


# ---- 原生资源路径 ----

def output_path(client, language, file=""):
    if client == "android":
        return f"RawLabAndroid/app/src/main/res/{ANDROID_DIRS[language]}/{file}"
    if client == "windows":
        return f"RawLabWindows/Resources/Localization/{language}.json"
    prefix = {"macos": "RawLabMac", "ios": "RawLab/RawLab"}[client]
    return f"{prefix}/Resources/{language}.lproj/Localizable.strings"
