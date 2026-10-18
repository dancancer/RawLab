"""对照迁移前提交，生成键集合、译文变化和 Android 反查报告。"""

import argparse
from collections import Counter, defaultdict
import csv
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from catalogs import CLIENTS, LANGUAGES, load, output_path
from formats import android_unquote, normalize, read_apple


# ---- 独立解析迁移前后资源 ----

def parse(text, client):
    if client == "android":
        return {node.attrib["name"]: android_unquote(node.text) for node in ET.fromstring(text)}
    if client == "windows":
        return json.loads(text)
    return read_apple(text)


def catalogs(root, base, client, language):
    files = ("strings.xml", "editor_strings.xml") if client == "android" else ("",)
    pairs = []
    for file in files:
        name = output_path(client, language, file)
        before = subprocess.check_output(["git", "show", base + ":" + name], cwd=root).decode("utf-8")
        after = (root / name).read_text(encoding="utf-8")
        pairs.append((name, parse(before, client), parse(after, client)))
    return pairs


def encoded(value):
    # 用 JSON 字面量保证制表符和换行不破坏 TSV 的一条一行。
    return json.dumps(value, ensure_ascii=False)


def write_tsv(path, header, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t")
        writer.writerow(header)
        writer.writerows(rows)


# ---- 键集合、格式与译文来源自证 ----

def audit_client(root, base, client, changes, keysets, baseline):
    counts = {}
    style = client if client in ("windows", "android") else "apple"
    for language in LANGUAGES:
        counts[language] = 0
        baseline[client][language] = {}
        for name, before, after in catalogs(root, base, client, language):
            if set(before) != set(after):
                raise ValueError(f"Key set changed: {name}: {set(before) ^ set(after)}")
            keysets.append([name, len(before), len(after), "identical", "[]", "[]"])
            baseline[client][language].update(before)
            counts[language] += audit_values(client, language, before, after, style, changes)
    return counts


def audit_values(client, language, before, after, style, changes):
    count = 0
    for key in sorted(before):
        old_neutral, old_slots = normalize(before[key], style)
        new_neutral, new_slots = normalize(after[key], style)
        if old_slots != new_slots:
            raise ValueError(f"Argument type/precision changed: {client}/{language}/{key}")
        if before[key] != after[key]:
            changes.append([client, language, encoded(key), encoded(before[key]), encoded(after[key]),
                            "translation" if old_neutral != new_neutral else "format-only"])
            count += 1
    return count


def verify_priority(shared, platforms, baseline):
    candidates = defaultdict(list)
    for client in CLIENTS:
        style = client if client in ("windows", "android") else "apple"
        for key, entry in platforms[client]["entries"].items():
            native = baseline[client]["zh-Hans"][key] if client == "android" else key
            if normalize(native, style)[0] != entry["source"]:
                raise ValueError(f"Original key/Chinese reverse lookup changed: {client}/{key}")
            values = {language: normalize(baseline[client][language][key], style)[0] for language in LANGUAGES}
            candidates[entry["source"]].append((client, key, values))
    for source, entries in candidates.items():
        client, _, expected = entries[0]
        actual = shared[source] if source in shared else platforms[client]["unique"][source]
        if actual != expected:
            raise ValueError(f"Baseline priority or original translation violated: {source}")
        verify_overrides(source, entries, platforms)
    return candidates


def verify_overrides(source, entries, platforms):
    for client, _, original in entries:
        override = platforms[client]["overrides"].get(source)
        if override is not None and override["values"] != original:
            raise ValueError(f"Platform override rewrites the baseline translation: {client}/{source}")


def reverse_rows(candidates):
    rows = []
    for source, entries in sorted(candidates.items()):
        android = [key for client, key, _ in entries if client == "android"]
        others = [client + ":" + key for client, key, _ in entries if client != "android"]
        if android and (len(android) > 1 or not others):
            status = "duplicate-chinese" if len(android) > 1 else "no-exact-counterpart"
            rows.append([status, encoded(source), ", ".join(android), encoded(others)])
    return rows


def summary(shared, platforms, counts, reverse, keysets):
    return {
        "shared": len(shared),
        "platform_unique": {client: len(platforms[client]["unique"]) for client in CLIENTS},
        "platform_keys": {client: len(platforms[client]["entries"]) for client in CLIENTS},
        "overrides": {client: platforms[client]["overrides"] for client in CLIENTS},
        "value_changes": counts,
        "android_reverse_status": dict(Counter(row[0] for row in reverse)),
        "key_sets_identical": len(keysets),
        "deleted_dead_keys": [],
        "priority_check": "Mac -> iOS -> Windows -> Android: exact baseline translations",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="c74e3ea", help="Pre-migration commit")
    parser.add_argument("--output", type=Path, required=True, help="Directory for audit reports")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    shared, platforms = load(root)
    changes, keysets, baseline = [], [], {client: {} for client in CLIENTS}
    counts = {client: audit_client(root, args.base, client, changes, keysets, baseline) for client in CLIENTS}
    candidates = verify_priority(shared, platforms, baseline)
    reverse = reverse_rows(candidates)
    result = summary(shared, platforms, counts, reverse, keysets)
    args.output.mkdir(parents=True, exist_ok=True)
    write_tsv(args.output / "value-changes.tsv", ["client", "language", "key", "before", "after", "kind"], changes)
    write_tsv(args.output / "key-sets.tsv", ["file", "before", "after", "result", "added", "deleted"], keysets)
    write_tsv(args.output / "android-reverse-lookup.tsv",
              ["status", "source", "android_resources", "other_platform_keys"], reverse)
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    (args.output / "migration-summary.json").write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    main()
