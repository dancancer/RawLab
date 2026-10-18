"""平台格式与中性占位符之间的无损转换。"""

import json
import re
import string
from xml.sax.saxutils import escape

PRINTF = re.compile(r"%%|%(?:(\d+)\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:[hlLzjt]+)?[@diufegsc]", re.I)
DOTNET = re.compile(r"\{(\d+)(?:,[+-]?\d+)?(?::[^{}]+)?\}")
QUOTED = r'"(?:[^"\\]|\\.)*"'
APPLE_TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|(' + QUOTED + r')\s*=\s*(' + QUOTED + r')\s*;', re.S)


# ---- 原生文件编码 ----

def apple_quote(value):
    return json.dumps(value, ensure_ascii=False)


def read_apple(text):
    entries, offset = {}, 0
    while offset < len(text):
        match = APPLE_TOKEN.match(text, offset)
        if not match:
            raise ValueError(f"Invalid .strings syntax at offset {offset}")
        offset = match.end()
        if match.group(1):
            key, value = (json.loads(part) for part in match.groups())
            if key in entries:
                raise ValueError(f"Duplicate .strings key: {key}")
            entries[key] = value
    return entries


def android_quote(value):
    replacements = {"\\": "\\\\", "'": "\\'", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}
    encoded = "".join(replacements.get(char, char) for char in value)
    if encoded.startswith(("@", "?")):
        encoded = "\\" + encoded
    # 外层引号保留连续空格及首尾空白；它们不是显示内容。
    return '"' + escape(encoded) + '"'


def android_unquote(value):
    text = value or ""
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    replacements = {"n": "\n", "t": "\t", "r": "\r"}
    return re.sub(r"\\(.)", lambda m: replacements.get(m[1], m[1]), text)


# ---- 中性占位符 ----

def normalize(value, style):
    if style == "windows":
        return _normalize_windows(value)
    slots, pieces, offset, sequential = {}, [], 0, 0
    for match in PRINTF.finditer(value):
        pieces.append(_literal(value[offset:match.start()]))
        offset = match.end()
        if match[0] == "%%":
            pieces.append("%")
            continue
        index = _index(match, style, sequential)
        sequential += 1
        _record_slot(slots, index, _positioned(match[0], index, style))
        pieces.append("{" + str(index) + "}")
    pieces.append(_literal(value[offset:]))
    return _normalized(pieces, slots)


def _normalize_windows(value):
    pieces, slots = [], {}
    for literal, field, spec, conversion in string.Formatter().parse(value):
        pieces.append(_literal(literal))
        if field is None:
            continue
        token = "{" + field + (":" + spec if spec else "") + "}"
        match = DOTNET.fullmatch(token)
        if not match or conversion:
            raise ValueError(f"Invalid .NET argument: {value}")
        index = int(match[1])
        _record_slot(slots, index, token)
        pieces.append("{" + str(index) + "}")
    return _normalized(pieces, slots)


def _record_slot(slots, index, token):
    if index in slots and slots[index] != token:
        raise ValueError(f"Conflicting native formats for argument {index}")
    slots[index] = token


def _normalized(pieces, slots):
    if set(slots) != set(range(len(slots))):
        raise ValueError(f"Non-contiguous arguments: {slots}")
    return "".join(pieces), [slots[index] for index in range(len(slots))]


def _literal(value):
    return value.replace("{", "{{").replace("}", "}}")


def _index(match, style, sequential):
    if style == "windows":
        return int(match[1])
    return int(match[1]) - 1 if match[1] else sequential


def _positioned(token, index, style):
    if style != "android" or re.match(r"%\d+\$", token):
        return token
    return "%" + str(index + 1) + "$" + token[1:]


def render(value, slots, style):
    parts = list(string.Formatter().parse(value))
    indices = [int(field) for _, field, spec, conversion in parts if field is not None]
    if set(indices) != set(range(len(slots))):
        raise ValueError(f"Placeholder mismatch: {value!r}, {slots!r}")
    positional = style == "apple" and indices != list(range(len(slots)))
    return "".join(_render_part(part, slots, style, positional) for part in parts)


def _render_part(part, slots, style, positional):
    literal, field, spec, conversion = part
    if spec or conversion:
        raise ValueError(f"Native formatting belongs in the platform mapping: {part}")
    if slots and style != "windows":
        literal = literal.replace("%", "%%")
    if style == "windows":
        literal = _literal(literal)
    if field is None:
        return literal
    token = slots[int(field)]
    if positional and not re.match(r"%\d+\$", token):
        token = "%" + str(int(field) + 1) + "$" + token[1:]
    return literal + token
