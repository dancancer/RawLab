#!/usr/bin/env bash
set -euo pipefail

# Deterministic regeneration of Shared/fixtures/abi-layout-v1.json from the C ABI headers,
# gated by a Clang JSON AST check so non-portable types (`long`, `unsigned long`, `wchar_t`),
# fields added inside alignment padding, struct/enum/function/callback drift, or missing
# `extern "C"` linkage fail immediately before updating the fixture.
#
# Compatibility policy:
#   - `version` stays `1` for backward compatibility with v1 consumers (e.g. Windows
#     `AbiLayoutChecks.cs`) that read `version`, `source`, and `structs` and ignore unknown
#     top-level sections.
#   - `fixture_version` increments (`3`) for additive top-level sections (`functions`, `enums`,
#     `callbacks`).
#
# Dependencies:
#   - clang++: required for `-Xclang -ast-dump=json` (on Linux/Ubuntu `c++` defaults to GCC/g++,
#     so this script defaults to `clang++`; override with `CXX=/path/to/clang++` if needed).
#   - python3: standard library only.
#
# Ordering rules (enforced in generate_abi_layout.cpp and verified against AST):
#   1. Complete structs, exported functions, named `sony2fuji_*` enums, and callback typedefs
#      from lutools/include/sony2fuji/ffi/sony2fuji_c.h in declaration order.
#   2. Complete structs, exported functions, named `sony2fuji_*` enums, and callback typedefs
#      from lutools/include/sony2fuji/ffi/sony2fuji_hdr.h in declaration order.
#   3. Fields within each struct, parameters within each function, enumerators within
#      each enum, and parameters within each callback in C declaration order.

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

"$TMP_DIR/generate_abi_layout" > "$TMP_DIR/structs-only.json"

cat > "$TMP_DIR/abi_ast_tu.cpp" <<'EOF'
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
EOF

"$CXX_BIN" -std=c++17 -Xclang -ast-dump=json -fsyntax-only \
    -I"$INCLUDE_DIR" \
    "$TMP_DIR/abi_ast_tu.cpp" > "$TMP_DIR/ast.json"

python3 - "$TMP_DIR/ast.json" "$TMP_DIR/structs-only.json" "$C_HEADER" "$HDR_HEADER" \
    "$CXX_BIN" "$INCLUDE_DIR" "$TMP_DIR" "$TMP_DIR/abi-layout-v1.json" <<'PY'
import json
import os
import re
import subprocess
import sys

(
    ast_path,
    structs_fixture_path,
    c_header,
    hdr_header,
    cxx_bin,
    include_dir,
    tmp_dir,
    out_fixture_path,
) = sys.argv[1:9]

c_real = os.path.realpath(c_header)
hdr_real = os.path.realpath(hdr_header)
header_order = [c_real, hdr_real]
target_headers = set(header_order)

with open(ast_path, "r", encoding="utf-8") as f:
    ast_root = json.load(f)
with open(structs_fixture_path, "r", encoding="utf-8") as f:
    structs_text = f.read()
structs_fixture = json.loads(structs_text)

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
TYPE_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[*()\[\],]")
CV_ORDER = ("const", "volatile")

current_file = None
records_by_id = {}
enums_by_id = {}
structs_by_header = {h: {} for h in header_order}
enums_by_header = {h: {} for h in header_order}
functions_by_header = {h: {} for h in header_order}
callbacks_by_header = {h: {} for h in header_order}
typedef_underlying = {}
identity_typedefs = {}
record_stack = []
type_checks = []
linkage_errors = []
prototype_errors = []
inline_gate_errors = []

ALLOWED_TYPE_KINDS = {
    "PointerType",
    "ParenType",
    "AttributedType",
    "ElaboratedType",
    "DecayedType",
    "QualType",
    "TypedefType",
}

# Matches an inline function-pointer declarator inside a qualType string, e.g.
# `int32_t (*)(void *)` or `int32_t (*[2])(void)`. Typedef'd types render by name
# (no parens) and pointer-to-array types like `int (*)[4]` do not match.
INLINE_FUNCTION_POINTER_RE = re.compile(r"\([^()]*\*[^()]*\)\s*\(")


def find_function_proto(node, pointer_depth=0):
    """Return (FunctionProtoType node, PointerType levels traversed) or None.

    TypedefType and QualType wrappers are traversed so second-level callback aliases
    and cv-qualified function-pointer typedefs are not silently skipped; the counted
    pointer depth lets the caller reject plain function typedefs (depth 0) and
    pointer-to-pointer callback declarations (depth >= 2).
    """
    if not isinstance(node, dict):
        return None
    kind = node.get("kind")
    if kind == "FunctionProtoType":
        return (node, pointer_depth)
    for child in node.get("inner", []):
        if not isinstance(child, dict):
            continue
        ckind = child.get("kind")
        if ckind in ALLOWED_TYPE_KINDS or ckind == "FunctionProtoType":
            found = find_function_proto(
                child, pointer_depth + (1 if ckind == "PointerType" else 0)
            )
            if found:
                return found
    return None


def strip_top_level_qual(node):
    """Return the qualType string of a type node, unwrapping a cv-qualified QualType.

    Clang keeps top-level parameter qualifiers in function-pointer typedef protos as a
    `QualType` wrapper (e.g. `void *const`); the underlying pointer type is what defines
    the callback ABI.
    """
    if not isinstance(node, dict):
        return ""
    if node.get("kind") == "QualType":
        for child in node.get("inner", []):
            if isinstance(child, dict):
                sub_qual = (child.get("type") or {}).get("qualType", "")
                if sub_qual:
                    return sub_qual
    return (node.get("type") or {}).get("qualType", "")


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


def extract_enumerators(enum_node):
    names = []
    for child in enum_node.get("inner", []):
        if not isinstance(child, dict) or child.get("isImplicit"):
            continue
        if child.get("kind") == "EnumConstantDecl":
            ename = child.get("name")
            if ename:
                names.append(ename)
    return names


def find_decl_id_by_type_kind(node, type_kind):
    if not isinstance(node, dict):
        return None
    if node.get("kind") == type_kind:
        decl = node.get("decl")
        if isinstance(decl, dict):
            return decl.get("id")
    for child in node.get("inner", []):
        found = find_decl_id_by_type_kind(child, type_kind)
        if found:
            return found
    return None


def extract_return_type(fn_qual):
    if not fn_qual:
        return ""
    depth = 0
    first_open = None
    first_close = None
    for idx, ch in enumerate(fn_qual):
        if ch == "(":
            if depth == 0 and first_open is None:
                first_open = idx
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and first_open is not None and first_close is None:
                first_close = idx
                break
    if first_open is None or first_close is None:
        return fn_qual.strip()
    if first_close == len(fn_qual) - 1:
        return fn_qual[:first_open].strip()
    # Function returning a pointer to function/array: e.g. `int32_t (*(int32_t))(void *)`
    inner = fn_qual[first_open + 1 : first_close]
    sub_depth = 0
    param_open = None
    param_close = None
    for idx, ch in enumerate(inner):
        if ch == "(":
            if sub_depth == 0 and param_open is None:
                param_open = idx
            sub_depth += 1
        elif ch == ")":
            sub_depth -= 1
            if sub_depth == 0 and param_open is not None:
                param_close = idx
                break
    if param_open is not None and param_close is not None:
        stripped_inner = inner[:param_open] + inner[param_close + 1 :]
        return (fn_qual[: first_open + 1] + stripped_inner + fn_qual[first_close:]).strip()
    return fn_qual[:first_open].strip()


def normalize_c_type(qual_type):
    cleaned = ANON_LOC_RE.sub("", qual_type)
    raw_tokens = TYPE_TOKEN_RE.findall(cleaned)
    tokens = []
    i = 0
    while i < len(raw_tokens):
        tok = raw_tokens[i]
        if tok in ("__restrict", "__restrict__"):
            tokens.append("restrict")
            i += 1
        elif (
            tok in ("struct", "enum")
            and i + 1 < len(raw_tokens)
            and identity_typedefs.get(raw_tokens[i + 1]) == f"{tok} {raw_tokens[i + 1]}"
        ):
            i += 1
        else:
            tokens.append(tok)
            i += 1

    # Canonicalize base-specifier const/volatile (east-const -> west-const) before '*',
    # while strictly preserving pointer-level qualifier order after '*'.
    norm = []
    i = 0
    at_type_start = True
    while i < len(tokens):
        if at_type_start and tokens[i] not in ("*", "(", ")", "[", "]", ","):
            j = i
            while j < len(tokens) and tokens[j] not in ("*", "(", ")", "[", "]", ","):
                j += 1
            seg = tokens[i:j]
            cv = [q for q in CV_ORDER if q in seg]
            rest = [t for t in seg if t not in CV_ORDER]
            norm.extend(cv + rest)
            i = j
            at_type_start = False
        else:
            tok = tokens[i]
            norm.append(tok)
            at_type_start = tok in ("(", ",")
            i += 1

    out = []
    for idx, curr in enumerate(norm):
        if idx == 0:
            out.append(curr)
            continue
        prev = norm[idx - 1]
        if curr in (",", ")", "]", "[") or prev in ("(", "["):
            out.append(curr)
        elif curr == "*":
            out.append(curr)
        elif curr == "(":
            out.append(curr if prev == ")" else " " + curr)
        else:
            out.append(" " + curr)
    return "".join(out)


def has_asm_label(node):
    for child in node.get("inner", []):
        if isinstance(child, dict) and child.get("kind") == "AsmLabelAttr":
            return True
    return False


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
            structs_by_header[node_file][info["name"]] = fields
        record_stack.append(info)
        pushed_record = True
    elif kind in ("TypedefDecl", "TypeAliasDecl") and not is_implicit:
        tname = node.get("name")
        qual_type = (node.get("type") or {}).get("qualType", "")
        if tname and qual_type and (in_target or tname not in typedef_underlying):
            typedef_underlying[tname] = qual_type
        if in_target and tname and qual_type in (f"struct {tname}", f"enum {tname}"):
            identity_typedefs[tname] = qual_type
        if kind == "TypedefDecl" and in_target:
            rec_id = find_decl_id_by_type_kind(node, "RecordType")
            if rec_id in records_by_id and not records_by_id[rec_id]["name"]:
                if tname:
                    records_by_id[rec_id]["typedef_name"] = tname
                    structs_by_header[node_file][tname] = records_by_id[rec_id]["fields"]
            enum_id = find_decl_id_by_type_kind(node, "EnumType")
            if enum_id in enums_by_id and not enums_by_id[enum_id]["name"]:
                if tname:
                    enums_by_id[enum_id]["typedef_name"] = tname
                    enums_by_header[node_file][tname] = enums_by_id[enum_id]["values"]
            found_proto = find_function_proto(node)
            if found_proto:
                proto, pointer_depth = found_proto
                if pointer_depth != 1:
                    prototype_errors.append(
                        f"  - typedef `{tname or '<unnamed>'}` in C ABI header must be a "
                        f"function-pointer callback typedef with exactly one pointer level; "
                        f"found {pointer_depth} (raw type `{qual_type}`)"
                    )
                elif tname:
                    inners = proto.get("inner", [])
                    ret_qual = strip_top_level_qual(inners[0]) if inners else ""
                    raw_params = [
                        strip_top_level_qual(child)
                        for child in inners[1:]
                        if isinstance(child, dict)
                    ]
                    if ret_qual:
                        type_checks.append(("callback_return", tname, None, ret_qual))
                    for idx, p_qual in enumerate(raw_params):
                        if p_qual:
                            type_checks.append(("callback_param", tname, f"arg{idx + 1}", p_qual))
                            if INLINE_FUNCTION_POINTER_RE.search(p_qual):
                                inline_gate_errors.append(
                                    f"  - callback `{tname}` parameter `arg{idx + 1}` uses the "
                                    f"inline function pointer type `{p_qual}`; declare public "
                                    f"C ABI callbacks through a named `sony2fuji_*` callback typedef"
                                )
                    callbacks_by_header[node_file][tname] = {
                        "name": tname,
                        "raw_return_type": ret_qual,
                        "raw_params": raw_params,
                        "variadic": bool(proto.get("variadic")),
                    }
        if in_target and qual_type:
            type_checks.append(("typedef", None, tname or "<unnamed>", qual_type))
    elif kind == "FieldDecl" and in_target and not is_implicit:
        qual_type = (node.get("type") or {}).get("qualType", "")
        if qual_type:
            fname = node.get("name") or "<unnamed>"
            type_checks.append(("field", list(record_stack), fname, qual_type))
            if INLINE_FUNCTION_POINTER_RE.search(qual_type):
                names = [r.get("name") or r.get("typedef_name") for r in record_stack]
                names = [n for n in names if n]
                struct_label = ".".join(names) if names else "<anonymous struct>"
                inline_gate_errors.append(
                    f"  - struct `{struct_label}.{fname}` uses the inline function pointer "
                    f"type `{qual_type}`; declare public C ABI callbacks through a named "
                    f"`sony2fuji_*` callback typedef"
                )
    elif kind == "EnumDecl" and not is_implicit:
        ename = node.get("name")
        evalues = extract_enumerators(node)
        einfo = {"name": ename, "file": node_file, "values": evalues}
        enums_by_id[node.get("id")] = einfo
        if in_target:
            if ename:
                identity_typedefs.setdefault(ename, f"enum {ename}")
                if evalues:
                    enums_by_header[node_file][ename] = evalues
            fixed_qual = (node.get("fixedUnderlyingType") or {}).get("qualType", "")
            if fixed_qual:
                type_checks.append(("enum", None, ename or "<unnamed>", fixed_qual))
    elif kind == "FunctionDecl" and in_target and not is_implicit:
        if node.get("storageClass") != "static" and not node.get("isInline"):
            fn_name = node.get("name") or "<unnamed>"
            fn_qual = (node.get("type") or {}).get("qualType", "")
            ret_qual = extract_return_type(fn_qual)
            if ret_qual:
                type_checks.append(("return", fn_name, None, ret_qual))
            raw_params = []
            for child in node.get("inner", []):
                if isinstance(child, dict) and child.get("kind") == "ParmVarDecl" and not child.get("isImplicit"):
                    p_qual = (child.get("type") or {}).get("qualType", "")
                    if p_qual:
                        type_checks.append(("param", fn_name, child.get("name") or "<unnamed>", p_qual))
                        if INLINE_FUNCTION_POINTER_RE.search(p_qual):
                            inline_gate_errors.append(
                                f"  - function `{fn_name}` parameter `{child.get('name') or '<unnamed>'}` "
                                f"uses the inline function pointer type `{p_qual}`; declare public "
                                f"C ABI callbacks through a named `sony2fuji_*` callback typedef"
                            )
                    raw_params.append(p_qual)
            mangled = node.get("mangledName") or ""
            if has_asm_label(node) or mangled not in (fn_name, f"_{fn_name}"):
                linkage_errors.append(
                    f"  - function `{fn_name}` does not have unmangled extern \"C\" linkage (mangledName=`{mangled}`)"
                )
            functions_by_header[node_file][fn_name] = {
                "name": fn_name,
                "raw_return_type": ret_qual,
                "raw_params": raw_params,
                "variadic": bool(node.get("variadic")),
                "symbol": fn_name,
            }

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

ast_structs = {}
ast_enums = {}
ast_functions = []
seen_functions = set()
ast_callbacks = []
seen_callbacks = set()
for h in header_order:
    for sname, sfields in structs_by_header[h].items():
        ast_structs[sname] = sfields
    for ename, evals in enums_by_header[h].items():
        ast_enums[ename] = evals
    for fn_name, fn_info in functions_by_header[h].items():
        if fn_name in seen_functions:
            continue
        seen_functions.add(fn_name)
        params = [normalize_c_type(p) for p in fn_info["raw_params"]]
        if fn_info["variadic"]:
            params.append("...")
        ast_functions.append(
            {
                "name": fn_name,
                "return_type": normalize_c_type(fn_info["raw_return_type"]),
                "params": params,
                "symbol": fn_info["symbol"],
            }
        )
    for cb_name, cb_info in callbacks_by_header[h].items():
        if cb_name in seen_callbacks:
            continue
        seen_callbacks.add(cb_name)
        params = [normalize_c_type(p) for p in cb_info["raw_params"]]
        if cb_info["variadic"]:
            params.append("...")
        ast_callbacks.append(
            {
                "name": cb_name,
                "return_type": normalize_c_type(cb_info["raw_return_type"]),
                "params": params,
            }
        )

if not ast_structs:
    sys.stderr.write("AST check failed: extracted 0 structs from target C ABI headers\n")
    sys.exit(1)
if not ast_functions:
    sys.stderr.write("AST check failed: extracted 0 functions from target C ABI headers\n")
    sys.exit(1)
if not ast_enums:
    sys.stderr.write("AST check failed: extracted 0 named enums from target C ABI headers\n")
    sys.exit(1)
if not ast_callbacks:
    sys.stderr.write("AST check failed: extracted 0 callbacks from target C ABI headers\n")
    sys.exit(1)

gen_structs = {
    entry["name"]: [field["name"] for field in entry["fields"]]
    for entry in structs_fixture.get("structs", [])
}

errors = list(linkage_errors) + list(prototype_errors) + list(inline_gate_errors)

for ename in ast_enums:
    if not ename.startswith("sony2fuji_"):
        errors.append(f"  - named enum `{ename}` in C ABI header must use `sony2fuji_` prefix")

for fn in ast_functions:
    if not fn["name"].startswith("sony2fuji_"):
        errors.append(f"  - exported function `{fn['name']}` in C ABI header must use `sony2fuji_` prefix")

for cb in ast_callbacks:
    if not cb["name"].startswith("sony2fuji_"):
        errors.append(f"  - callback `{cb['name']}` in C ABI header must use `sony2fuji_` prefix")

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
    elif check_kind == "callback_return":
        subject = f"callback `{owner}` return type"
    elif check_kind == "callback_param":
        subject = f"callback `{owner}` parameter `{member}`"
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

# Compile a C++17 probe to evaluate exact enum sizes and constant values via the compiler,
# and verify every extracted function symbol is addressable in C++.
probe_cpp = os.path.join(tmp_dir, "abi_enum_fn_probe.cpp")
probe_bin = os.path.join(tmp_dir, "abi_enum_fn_probe")

probe_lines = [
    '#include "sony2fuji/ffi/sony2fuji_c.h"',
    '#include "sony2fuji/ffi/sony2fuji_hdr.h"',
    "#include <cstddef>",
    "#include <cstdint>",
    "#include <iostream>",
    "#include <type_traits>",
    'static_assert(sizeof(void*) == 8, "64-bit C ABI target required");',
    'static_assert(sizeof(size_t) == 8, "64-bit size_t required");',
    "template <typename E>",
    "void print_enum_value(E v) {",
    "    using U = std::underlying_type_t<E>;",
    "    if constexpr (std::is_signed_v<U>) {",
    "        std::cout << static_cast<int64_t>(v);",
    "    } else {",
    "        std::cout << static_cast<uint64_t>(v);",
    "    }",
    "}",
    "int main() {",
]

for fn in ast_functions:
    probe_lines.append(f"    (void)&{fn['name']};")
for cb in ast_callbacks:
    probe_lines.append(f"    (void)sizeof({cb['name']});")

probe_lines.append('    std::cout << "[\\n";')
enum_items = list(ast_enums.items())
for e_idx, (ename, evals) in enumerate(enum_items):
    e_comma = "," if e_idx + 1 < len(enum_items) else ""
    probe_lines.append('    std::cout << "  {\\"enum\\": \\"' + ename + '\\", \\"size\\": " << sizeof(' + ename + ') << ", \\"values\\": [\\n";')
    for v_idx, vname in enumerate(evals):
        v_comma = "," if v_idx + 1 < len(evals) else ""
        probe_lines.append(
            f'    std::cout << "    {{\\"name\\": \\"{vname}\\", \\"value\\": "; '
            f"print_enum_value({vname}); "
            f'std::cout << "}}{v_comma}\\n";'
        )
    probe_lines.append(f'    std::cout << "  ]}}{e_comma}\\n";')
probe_lines.append('    std::cout << "]\\n";')
probe_lines.append("    return 0;")
probe_lines.append("}")

with open(probe_cpp, "w", encoding="utf-8") as f:
    f.write("\n".join(probe_lines) + "\n")

subprocess.run(
    [cxx_bin, "-std=c++17", "-Wall", "-Wextra", "-Werror", f"-I{include_dir}", probe_cpp, "-o", probe_bin],
    check=True,
)
probe_out = subprocess.check_output([probe_bin], text=True)
enums_evaluated = json.loads(probe_out)

# Preserve the exact structs block emitted by generate_abi_layout.cpp and append functions + enums + callbacks.
closing_suffix = "\n  ]\n}\n"
if not structs_text.endswith(closing_suffix):
    sys.stderr.write("Unexpected generate_abi_layout output tail\n")
    sys.exit(1)

out_lines = [structs_text[: -len(closing_suffix)] + "\n  ],"]
out_lines.append('  "functions": [')
for idx, fn in enumerate(ast_functions):
    comma = "," if idx + 1 < len(ast_functions) else ""
    out_lines.append("    {")
    out_lines.append(f'      "name": {json.dumps(fn["name"])},')
    out_lines.append(f'      "return_type": {json.dumps(fn["return_type"])},')
    out_lines.append(f'      "params": {json.dumps(fn["params"])},')
    out_lines.append(f'      "symbol": {json.dumps(fn["symbol"])}')
    out_lines.append(f"    }}{comma}")
out_lines.append("  ],")

out_lines.append('  "enums": [')
for idx, en in enumerate(enums_evaluated):
    comma = "," if idx + 1 < len(enums_evaluated) else ""
    out_lines.append("    {")
    out_lines.append(f'      "enum": {json.dumps(en["enum"])},')
    out_lines.append(f'      "size": {en["size"]},')
    out_lines.append('      "values": [')
    for v_idx, val in enumerate(en["values"]):
        v_comma = "," if v_idx + 1 < len(en["values"]) else ""
        out_lines.append(
            f'        {{"name": {json.dumps(val["name"])}, "value": {val["value"]}}}{v_comma}'
        )
    out_lines.append("      ]")
    out_lines.append(f"    }}{comma}")
out_lines.append("  ],")

out_lines.append('  "callbacks": [')
for idx, cb in enumerate(ast_callbacks):
    comma = "," if idx + 1 < len(ast_callbacks) else ""
    out_lines.append("    {")
    out_lines.append(f'      "name": {json.dumps(cb["name"])},')
    out_lines.append(f'      "return_type": {json.dumps(cb["return_type"])},')
    out_lines.append(f'      "params": {json.dumps(cb["params"])}')
    out_lines.append(f"    }}{comma}")
out_lines.append("  ]")
out_lines.append("}")

final_text = "\n".join(out_lines) + "\n"
parsed_final = json.loads(final_text)
assert parsed_final["version"] == 1
assert parsed_final["fixture_version"] == 3
assert len(parsed_final["structs"]) == len(structs_fixture["structs"])
assert len(parsed_final["functions"]) == len(ast_functions)
assert len(parsed_final["enums"]) == len(ast_enums)
assert len(parsed_final["callbacks"]) == len(ast_callbacks)

with open(out_fixture_path, "w", encoding="utf-8") as f:
    f.write(final_text)
PY

mv "$TMP_DIR/abi-layout-v1.json" "$OUT"
