"""从共享来源稳定生成四端六语资源；--check 只读检查。"""

import argparse
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

from catalogs import CLIENTS, LANGUAGES, load, output_path, translated
from formats import android_quote, apple_quote

NOTICE = "由 scripts/localization/generate.py 生成，勿手改"


# ---- 原生序列化 ----

def apple_text(values):
    lines = [f"/* {NOTICE} */"]
    lines.extend(f"{apple_quote(key)} = {apple_quote(value)};" for key, value in sorted(values.items()))
    return "\n".join(lines) + "\n"


def android_text(values):
    lines = ['<?xml version="1.0" encoding="utf-8"?>', f"<!-- {NOTICE} -->", "<resources>"]
    lines.extend(f'    <string name="{key}">{android_quote(value)}</string>' for key, value in sorted(values.items()))
    return "\n".join(lines + ["</resources>", ""])


def generated(root):
    shared, platforms = load(root)
    result = {}
    for client in CLIENTS:
        for language in LANGUAGES:
            result.update(generate_language(shared, platforms[client], client, language))
    return result


def generate_language(shared, platform, client, language):
    values = {key: translated(shared, platform, entry, language, client)
              for key, entry in platform["entries"].items()}
    if client == "android":
        return {output_path(client, language, file): android_text({
            key: value for key, value in values.items() if platform["entries"][key]["file"] == file
        }) for file in ("strings.xml", "editor_strings.xml")}
    text = apple_text(values)
    if client == "windows":
        # 严格 JSON 不能写注释，否则现有 System.Text.Json 读取器会拒绝。
        text = json.dumps(values, ensure_ascii=False, indent=4, sort_keys=True) + "\n"
    return {output_path(client, language): text}


# ---- 全量文件与游离资源检查 ----

def catalog_files(root):
    paths = set()
    for prefix in ("RawLabMac", "RawLab/RawLab"):
        paths.update((root / prefix / "Resources").glob("*.lproj/Localizable.strings"))
    paths.update((root / "RawLabWindows/Resources/Localization").glob("*.json"))
    resource_root = root / "RawLabAndroid/app/src/main/res"
    for path in resource_root.glob("values*/*.xml"):
        if any(node.tag in ("string", "plurals", "string-array") for node in ET.parse(path).getroot()):
            paths.add(path)
    return {path.relative_to(root).as_posix() for path in paths}


def check(root, outputs):
    errors = [f"Unowned catalog: {path}" for path in sorted(catalog_files(root) - outputs.keys())]
    for name, text in outputs.items():
        path = root / name
        if not path.is_file() or path.read_bytes() != text.encode("utf-8"):
            errors.append(f"Generated catalog differs: {name}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare bytes without writing files")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        outputs = generated(args.root)
        errors = check(args.root, outputs)
        if args.check:
            return report(errors, len(outputs))
        unowned = [error for error in errors if error.startswith("Unowned")]
        if unowned:
            return report(unowned, len(outputs))
        for name, text in outputs.items():
            path = args.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(text.encode("utf-8"))
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError) as error:
        print(f"Localization source error: {error}", file=sys.stderr)
        return 1
    print(f"Generated {len(outputs)} catalogs from Shared/strings")
    return 0


def report(errors, count):
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Checked {count} catalogs: byte-identical; no unowned resources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
