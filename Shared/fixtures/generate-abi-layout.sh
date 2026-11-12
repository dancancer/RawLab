#!/usr/bin/env bash
set -euo pipefail

# Deterministic regeneration of Shared/fixtures/abi-layout-v1.json from the C ABI headers,
# gated by a Clang JSON AST completeness check so fields added inside alignment padding
# (or new structs added to the headers) fail immediately unless registered in generate_abi_layout.cpp.
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

CXX_BIN="${CXX:-c++}"
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
import sys

ast_path, fixture_path, c_header, hdr_header = sys.argv[1:5]
target_headers = {os.path.realpath(c_header), os.path.realpath(hdr_header)}

with open(ast_path, "r", encoding="utf-8") as f:
    ast_root = json.load(f)
with open(fixture_path, "r", encoding="utf-8") as f:
    fixture = json.load(f)

current_file = None
records_by_id = {}
ast_structs = {}


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
    if kind in ("RecordDecl", "CXXRecordDecl") and node.get("completeDefinition"):
        fields = extract_fields(node)
        info = {"name": node.get("name"), "file": node_file, "fields": fields}
        records_by_id[node.get("id")] = info
        if info["name"] and node_file in target_headers:
            ast_structs[info["name"]] = fields
    elif kind == "TypedefDecl" and node_file in target_headers:
        decl_id = find_record_decl_id(node)
        if decl_id in records_by_id and not records_by_id[decl_id]["name"]:
            tname = node.get("name")
            if tname:
                ast_structs[tname] = records_by_id[decl_id]["fields"]

    for child in node.get("inner", []):
        walk(child)


walk(ast_root)

if not ast_structs:
    sys.stderr.write("AST check failed: extracted 0 structs from target C ABI headers\n")
    sys.exit(1)

gen_structs = {
    entry["name"]: [field["name"] for field in entry["fields"]]
    for entry in fixture.get("structs", [])
}

errors = []

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
    sys.stderr.write("ABI layout AST completeness check FAILED:\n" + "\n".join(errors) + "\n")
    sys.exit(1)
PY

mv "$TMP_DIR/abi-layout-v1.json" "$OUT"
