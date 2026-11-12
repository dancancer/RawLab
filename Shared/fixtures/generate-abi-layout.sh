#!/usr/bin/env bash
set -euo pipefail

# Deterministic regeneration of Shared/fixtures/abi-layout-v1.json from the C ABI headers,
# gated by a Clang JSON AST check so non-portable types (`long`, `unsigned long`, `wchar_t`)
# and fields added inside alignment padding (or new structs added to the headers) fail
# immediately before updating the fixture.
#
# Dependencies:
#   - clang++: required for `-Xclang -ast-dump=json` (on Linux/Ubuntu `c++` defaults to GCC/g++,
#     so this script defaults to `clang++`; override with `CXX=/path/to/clang++` if needed).
#   - python3: standard library only.
#
# Ordering rules (enforced in generate_abi_layout.cpp and verified against AST):
#   1. Complete structs from lutools/include/sony2fuji/ffi/sony2fuji_c.h in declaration order.
#   2. Complete structs from lutools/include/sony2fuji/ffi/sony2fuji_hdr.h in declaration order.
#   3. Fields within each struct in C declaration order.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/lutools/tools/abi-layout/generate_abi_layout.cpp"
INCLUDE_DIR="${ABI_LAYOUT_INCLUDE_DIR:-$REPO_ROOT/lutools/include}"
OUT="${ABI_LAYOUT_OUT:-$SCRIPT_DIR/abi-layout-v1.json}"

C_HEADER="$INCLUDE_DIR/sony2fuji/ffi/sony2fuji_c.h"
HDR_HEADER="$INCLUDE_DIR/sony2fuji/ffi/sony2fuji_hdr.h"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/abi-layout.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

CXX_BIN="${CXX:-clang++}"
if ! command -v "$CXX_BIN" >/dev/null 2>&1; then
    echo "Error: Clang C++ compiler '$CXX_BIN' not found in PATH." >&2
    echo "generate-abi-layout.sh requires Clang (for -Xclang -ast-dump=json); install clang++ or set CXX=/path/to/clang++." >&2
    exit 1
fi
if ! "$CXX_BIN" --version 2>&1 | grep -qi 'clang'; then
    CXX_FIRST_LINE="$("$CXX_BIN" --version 2>&1 | head -n 1 || true)"
    echo "Error: CXX='$CXX_BIN' is not Clang ($CXX_FIRST_LINE)." >&2
    echo "generate-abi-layout.sh requires Clang for '-Xclang -ast-dump=json' (GCC/g++ is unsupported); set CXX=clang++." >&2
    exit 1
fi
"$CXX_BIN" -std=c++17 -Wall -Wextra -Werror \
    -I"$INCLUDE_DIR" \
    "$SRC" \
    -o "$TMP_DIR/generate_abi_layout"

"$TMP_DIR/generate_abi_layout" > "$TMP_DIR/abi-layout-v1.json"

cat > "$TMP_DIR/abi_ast_tu.cpp" <<'EOF'
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
EOF

"$CXX_BIN" -std=c++17 -Xclang -ast-dump=json -fsyntax-only \
    -I"$INCLUDE_DIR" \
    "$TMP_DIR/abi_ast_tu.cpp" > "$TMP_DIR/ast.json"

python3 - "$TMP_DIR/ast.json" "$TMP_DIR/abi-layout-v1.json" "$C_HEADER" "$HDR_HEADER" <<'PY'
import json
import os
import re
import sys

ast_path, fixture_path, c_header, hdr_header = sys.argv[1:5]
target_headers = {os.path.realpath(c_header), os.path.realpath(hdr_header)}

with open(ast_path, "r", encoding="utf-8") as f:
    ast_root = json.load(f)
with open(fixture_path, "r", encoding="utf-8") as f:
    fixture = json.load(f)

PORTABLE_STD_TYPEDEFS = {
    "int8_t",
    "uint8_t",
    "int16_t",
    "uint16_t",
    "int32_t",
    "uint32_t",
    "int64_t",
    "uint64_t",
    "size_t",
    "ptrdiff_t",
    "intptr_t",
    "uintptr_t",
}

FORBIDDEN_TYPE_HINTS = {
    "long": "use a fixed-width type such as `int32_t` or `int64_t`",
    "unsigned long": "use a fixed-width type such as `uint32_t` or `uint64_t`",
    "wchar_t": "use UTF-8 `char` or a fixed-width type such as `uint16_t` or `uint32_t`",
}

ANON_LOC_RE = re.compile(r"\((?:anonymous|unnamed) [^)]*\)")
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

current_file = None
records_by_id = {}
ast_structs = {}
typedef_underlying = {}
record_stack = []
type_checks = []


def update_file_from_loc(obj):
    global current_file
    if not isinstance(obj, dict):
        return
    if isinstance(obj.get("file"), str):
        current_file = os.path.realpath(obj["file"])
    for key in ("spellingLoc", "expansionLoc", "begin", "end"):
        sub = obj.get(key)
        if isinstance(sub, dict):
            update_file_from_loc(sub)


def extract_fields(record_node):
    fields = []
    seen_indirect = set()
    for child in record_node.get("inner", []):
        if not isinstance(child, dict) or child.get("isImplicit"):
            continue
        ckind = child.get("kind")
        if ckind == "FieldDecl":
            fname = child.get("name")
            if fname:
                fields.append(fname)
        elif ckind == "IndirectFieldDecl":
            fname = child.get("name")
            if fname and fname not in seen_indirect:
                seen_indirect.add(fname)
                fields.append(fname)
    return fields


def find_record_decl_id(node):
    if not isinstance(node, dict):
        return None
    if node.get("kind") == "RecordType":
        decl = node.get("decl")
        if isinstance(decl, dict):
            return decl.get("id")
    for child in node.get("inner", []):
        found = find_record_decl_id(child)
        if found:
            return found
    return None


def walk(node):
    if not isinstance(node, dict):
        return
    update_file_from_loc(node.get("loc"))
    node_file = current_file
    update_file_from_loc(node.get("range"))

    kind = node.get("kind")
    in_target = node_file in target_headers
    is_implicit = bool(node.get("isImplicit"))
    pushed_record = False

    if kind in ("RecordDecl", "CXXRecordDecl") and node.get("completeDefinition"):
        fields = extract_fields(node)
        info = {"name": node.get("name"), "file": node_file, "fields": fields}
        records_by_id[node.get("id")] = info
        if info["name"] and in_target:
            ast_structs[info["name"]] = fields
        record_stack.append(info)
        pushed_record = True
    elif kind in ("TypedefDecl", "TypeAliasDecl") and not is_implicit:
        tname = node.get("name")
        qual_type = (node.get("type") or {}).get("qualType", "")
        if tname and qual_type and (in_target or tname not in typedef_underlying):
            typedef_underlying[tname] = qual_type
        if kind == "TypedefDecl" and in_target:
            decl_id = find_record_decl_id(node)
            if decl_id in records_by_id and not records_by_id[decl_id]["name"]:
                if tname:
                    records_by_id[decl_id]["typedef_name"] = tname
                    ast_structs[tname] = records_by_id[decl_id]["fields"]
        if in_target and qual_type:
            type_checks.append(("typedef", None, tname or "<unnamed>", qual_type))
    elif kind == "FieldDecl" and in_target and not is_implicit:
        qual_type = (node.get("type") or {}).get("qualType", "")
        if qual_type:
            type_checks.append(("field", list(record_stack), node.get("name") or "<unnamed>", qual_type))
    elif kind == "EnumDecl" and in_target and not is_implicit:
        fixed_qual = (node.get("fixedUnderlyingType") or {}).get("qualType", "")
        if fixed_qual:
            type_checks.append(("enum", None, node.get("name") or "<unnamed>", fixed_qual))
    elif kind == "FunctionDecl" and in_target and not is_implicit:
        fn_name = node.get("name") or "<unnamed>"
        fn_qual = (node.get("type") or {}).get("qualType", "")
        ret_qual = fn_qual if "(*" in fn_qual else fn_qual.split("(", 1)[0].strip()
        if ret_qual:
            type_checks.append(("return", fn_name, None, ret_qual))
        for child in node.get("inner", []):
            if isinstance(child, dict) and child.get("kind") == "ParmVarDecl" and not child.get("isImplicit"):
                p_qual = (child.get("type") or {}).get("qualType", "")
                if p_qual:
                    type_checks.append(("param", fn_name, child.get("name") or "<unnamed>", p_qual))

    for child in node.get("inner", []):
        walk(child)

    if pushed_record:
        record_stack.pop()


def find_forbidden_types(qual_type, seen_typedefs=None):
    if not qual_type:
        return []
    if seen_typedefs is None:
        seen_typedefs = set()
    cleaned = ANON_LOC_RE.sub("", qual_type)
    tokens = TOKEN_RE.findall(cleaned)
    found = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "wchar_t":
            if "wchar_t" not in found:
                found.append("wchar_t")
            i += 1
        elif tokens[i : i + 3] == ["unsigned", "long", "long"]:
            i += 3
        elif tokens[i : i + 2] == ["long", "long"]:
            i += 2
        elif tokens[i : i + 2] == ["long", "double"]:
            i += 2
        elif tokens[i : i + 2] == ["unsigned", "long"]:
            if "unsigned long" not in found:
                found.append("unsigned long")
            i += 2
        elif tok == "long":
            if "long" not in found:
                found.append("long")
            i += 1
        else:
            if (
                tok not in PORTABLE_STD_TYPEDEFS
                and tok in typedef_underlying
                and tok not in seen_typedefs
            ):
                for sub in find_forbidden_types(typedef_underlying[tok], seen_typedefs | {tok}):
                    if sub not in found:
                        found.append(sub)
            i += 1
    return found


walk(ast_root)

if not ast_structs:
    sys.stderr.write("AST check failed: extracted 0 structs from target C ABI headers\n")
    sys.exit(1)

gen_structs = {
    entry["name"]: [field["name"] for field in entry["fields"]]
    for entry in fixture.get("structs", [])
}

errors = []

for check_kind, owner, member, qual_type in type_checks:
    forbidden = find_forbidden_types(qual_type)
    if not forbidden:
        continue
    if check_kind == "field":
        names = [r.get("name") or r.get("typedef_name") for r in (owner or [])]
        names = [n for n in names if n]
        struct_label = ".".join(names) if names else "<anonymous struct>"
        subject = f"`{struct_label}.{member}`"
    elif check_kind == "typedef":
        subject = f"typedef `{member}`"
    elif check_kind == "enum":
        subject = f"enum `{member}` underlying type"
    elif check_kind == "return":
        subject = (
            f"function `{owner}` signature"
            if "(*" in qual_type
            else f"function `{owner}` return type"
        )
    else:
        subject = f"function `{owner}` parameter `{member}`"

    for ftype in forbidden:
        hint = FORBIDDEN_TYPE_HINTS[ftype]
        if qual_type == ftype:
            detail = f"`{qual_type}` (width differs on Windows vs Unix)"
        else:
            detail = f"`{qual_type}` (uses `{ftype}`, whose width differs on Windows vs Unix)"
        errors.append(f"  - {subject}: forbidden C ABI type {detail}; {hint}")

for sname, afields in ast_structs.items():
    if sname not in gen_structs:
        errors.append(
            f"  - struct `{sname}` exists in C header AST (fields: {afields}) "
            f"but is missing from generate_abi_layout.cpp"
        )
        continue
    gfields = gen_structs[sname]
    missing_in_gen = [f for f in afields if f not in gfields]
    extra_in_gen = [f for f in gfields if f not in afields]
    if missing_in_gen:
        errors.append(
            f"  - `{sname}`: AST field(s) missing from generator ABI_FIELD list: {missing_in_gen} "
            f"(AST={afields}, generator={gfields})"
        )
    if extra_in_gen:
        errors.append(
            f"  - `{sname}`: generator lists field(s) not present in AST: {extra_in_gen}"
        )
    if not missing_in_gen and not extra_in_gen and afields != gfields:
        errors.append(
            f"  - `{sname}`: field declaration order mismatch (AST={afields}, generator={gfields})"
        )

for sname in gen_structs:
    if sname not in ast_structs:
        errors.append(f"  - struct `{sname}` listed in generator but not found in C header AST")

if not errors and list(ast_structs.keys()) != list(gen_structs.keys()):
    errors.append(
        "  - struct declaration order mismatch between C header AST and generator output"
    )

if errors:
    sys.stderr.write("ABI layout AST check FAILED:\n" + "\n".join(errors) + "\n")
    sys.exit(1)
PY

mv "$TMP_DIR/abi-layout-v1.json" "$OUT"
