#!/bin/bash
# ----------------------------------------------------------------------------
#  iOS 翻译目录的用词检查：抓机器翻译常见的歧义和语序错误
#  （键齐全、无夹杂中文、占位符一致由 tests/test_localization.py 负责）
# ----------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT/RawLab/RawLab/Resources" <<'PY'
import json, subprocess, sys
from pathlib import Path

resources = Path(sys.argv[1])
catalog = {language: json.loads(subprocess.check_output(
    ["plutil", "-convert", "json", "-o", "-", str(resources / f"{language}.lproj/Localizable.strings")]))
    for language in ("en", "de", "fr", "es", "ja")}
failures = []

def check(condition, message):
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures.append(message)

# 白平衡的"色调"（tint）和 HSL 的"色相"（hue）同屏出现，不能译成同一个词
# 法语沿用 Lightroom 的惯例两处都叫 Teinte，此处不查
for language in ("en", "de", "es", "ja"):
    check(catalog[language]["色调"] != catalog[language]["色相"],
          f"{language}: tint {catalog[language]['色调']!r} differs from hue {catalog[language]['色相']!r}")

# 进行中的状态（正在…）不能和动作按钮同文；德语统一用"wird / werden"被动进行式
for key, value in catalog["de"].items():
    if key.startswith("正在"):
        check(" wird " in f" {value.lower()} " or "werden" in value.lower(), f"de: progress {key} -> {value!r}")

# "重置某项"与通用的"重置%@"套出来的说法一致（英文大小写、日文语序）
for language in ("en", "ja"):
    expected = catalog[language]["重置%@"].replace("%@", catalog[language]["降噪"])
    check(catalog[language]["重置降噪"] == expected, f"{language}: reset denoise {catalog[language]['重置降噪']!r}")

sys.exit(1 if failures else 0)
PY
