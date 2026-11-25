"""Static guard for GPU-portable C++ tests.

Tests are built with exactly one native GPU backend: Metal (Apple), D3D11 (Windows) or GLES
(Android). A block guarded only by SONY2FUJI_ENABLE_METAL with an #else/#elif branch sends D3D11
and GLES builds down that "no Metal" branch, so an expectation written as "no GPU backend" there is
wrong wherever D3D11 or GLES implements the feature (viewport_pyramid_tests asserted a CPU-only
capability that Windows D3D11 builds provide; fixed in 338c5e14a). Such blocks must either cover
D3D11 and GLES in their conditions, or say why the non-Metal branch is right for them:

    #ifdef SONY2FUJI_ENABLE_METAL  // gpu-portability: metal-only <reason the feature has no D3D11/GLES path>
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNED = (ROOT / "lutools/tests",)
SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp"}
DIRECTIVE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)$")
ANNOTATION = re.compile(r"gpu-portability:\s*metal-only\s+\S")
NEGATED_METAL = re.compile(r"!\s*defined\s*\(?\s*SONY2FUJI_ENABLE_METAL\b")


def _without_block_comments(text):
    # Keep line numbers: replace each /* ... */ with the same number of newlines.
    return re.sub(r"/\*.*?\*/", lambda match: "\n" * match.group(0).count("\n"), text, flags=re.S)


def _condition(lines, index):
    """The directive's condition with `\\` continuations joined and the trailing // comment removed."""
    text = lines[index]
    while text.endswith("\\") and index + 1 < len(lines):
        index += 1
        text = text[:-1] + " " + lines[index]
    return text.split("//", 1)[0]


def metal_only_branches(text):
    """Return (line, directive) for unannotated conditionals that leave D3D11/GLES on a "no Metal" path.

    That is a SONY2FUJI_ENABLE_METAL conditional with an #else/#elif branch not covering D3D11 and
    GLES, or a negated one (#ifndef / !defined) whose only branch is the non-Metal one.
    """
    lines = text.splitlines()
    code = _without_block_comments(text).splitlines()
    stack, findings = [], []
    for index, line in enumerate(code):
        number = index + 1
        match = DIRECTIVE.match(line)
        if not match:
            continue
        kind = match.group(1)
        rest = _condition(code, index)[match.start(2):] if kind in ("if", "ifdef", "ifndef", "elif") else ""
        if kind in ("if", "ifdef", "ifndef"):
            annotated = bool(ANNOTATION.search(lines[index]) or (index > 0 and ANNOTATION.search(lines[index - 1])))
            negated = kind == "ifndef" or bool(NEGATED_METAL.search(rest))
            stack.append({"line": number, "text": lines[index].strip(), "conditions": [rest], "branches": 1,
                          "annotated": annotated, "negated": negated})
        elif kind in ("elif", "else") and stack:
            stack[-1]["branches"] += 1
            if kind == "elif":
                stack[-1]["conditions"].append(rest)
        elif kind == "endif" and stack:
            block = stack.pop()
            conditions = " ".join(block["conditions"])
            if block["negated"]:
                # "#if !METAL && !D3D11 && !GLES" means no GPU backend at all, which is correct.
                covers_other_gpus = all(re.search(rf"!\s*defined\s*\(?\s*SONY2FUJI_ENABLE_{name}\b", conditions)
                                        for name in ("D3D11", "GLES"))
            else:
                covers_other_gpus = all(re.search(rf"(?<!!)\bdefined\s*\(?\s*SONY2FUJI_ENABLE_{name}\b", conditions)
                                        for name in ("D3D11", "GLES"))
            has_non_metal_path = block["branches"] > 1 or block["negated"]
            if ("SONY2FUJI_ENABLE_METAL" in conditions and has_non_metal_path
                    and not covers_other_gpus and not block["annotated"]):
                findings.append((block["line"], block["text"]))
    return findings


class CppPortabilityGuardTests(unittest.TestCase):
    def test_metal_only_alternatives_in_tests_are_covered_or_justified(self):
        findings = []
        for directory in SCANNED:
            for path in sorted(directory.rglob("*")):
                if path.suffix in SUFFIXES and path.is_file():
                    for line, text in metal_only_branches(path.read_text(encoding="utf-8", errors="replace")):
                        findings.append(f"{path.relative_to(ROOT)}:{line}: {text}")
        self.assertEqual(findings, [], "cover D3D11/GLES or annotate `// gpu-portability: metal-only <reason>`:\n"
                         + "\n".join(findings))

    def test_historic_viewport_pyramid_trap_is_flagged(self):
        # The pre-338c5e14a shape: the #else asserted "no GPU" and broke on D3D11 builds.
        before = (
            "#ifdef SONY2FUJI_ENABLE_METAL\n"
            '    checkPass(supported == 1, "baseline SDR RAW supports fast full-res Metal GPU");\n'
            "#else\n"
            '    checkPass(supported == 0, "baseline returns 0 without GPU backend");\n'
            "#endif\n")
        self.assertEqual(metal_only_branches(before), [(1, "#ifdef SONY2FUJI_ENABLE_METAL")])
        after = (
            "#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_D3D11) || defined(SONY2FUJI_ENABLE_GLES)\n"
            "    expectGpu();\n#else\n    expectCpu();\n#endif\n")
        self.assertEqual(metal_only_branches(after), [])

    def test_alternatives_and_annotations(self):
        cases = {
            "#ifndef SONY2FUJI_ENABLE_METAL\nfail();\n#else\nrun();\n#endif\n": 1,
            "#if defined(SONY2FUJI_ENABLE_METAL)\na();\n#elif defined(SONY2FUJI_ENABLE_D3D11)\nb();\n#else\nc();\n#endif\n": 1,
            "#if defined(SONY2FUJI_ENABLE_METAL)\na();\n#elif defined(SONY2FUJI_ENABLE_D3D11) || defined(SONY2FUJI_ENABLE_GLES)\nb();\n#else\nc();\n#endif\n": 0,
            "#ifdef SONY2FUJI_ENABLE_METAL\n#include <x>\n#endif\n": 0,
            "#ifdef SONY2FUJI_ENABLE_METAL  // gpu-portability: metal-only DCP looks have no D3D11/GLES path\na();\n#else\nb();\n#endif\n": 0,
            "// gpu-portability: metal-only the stats kernel is Metal-only\n#ifdef SONY2FUJI_ENABLE_METAL\na();\n#else\nb();\n#endif\n": 0,
            "#ifdef SONY2FUJI_ENABLE_METAL  // gpu-portability: metal-only\na();\n#else\nb();\n#endif\n": 1,
            "#ifdef SONY2FUJI_ENABLE_METAL\n#ifdef OTHER\nx();\n#else\ny();\n#endif\n#endif\n": 0,
            "#ifdef OTHER\n#ifdef SONY2FUJI_ENABLE_METAL\nx();\n#else\ny();\n#endif\n#endif\n": 1,
            # Single-branch negations still put D3D11/GLES on the "no Metal" path.
            "#ifndef SONY2FUJI_ENABLE_METAL\nexpectUnsupported();\n#endif\n": 1,
            "#if !defined(SONY2FUJI_ENABLE_METAL)\nexpectUnsupported();\n#endif\n": 1,
            "#if !defined(SONY2FUJI_ENABLE_METAL) && !defined(SONY2FUJI_ENABLE_GLES) && !defined(SONY2FUJI_ENABLE_D3D11)\ncpuOnly();\n#endif\n": 0,
            # Coverage must be real conditions, not text in a comment or a negation.
            "#ifdef SONY2FUJI_ENABLE_METAL // SONY2FUJI_ENABLE_D3D11 SONY2FUJI_ENABLE_GLES\na();\n#else\nb();\n#endif\n": 1,
            "#if defined(SONY2FUJI_ENABLE_METAL) && !defined(SONY2FUJI_ENABLE_D3D11) && !defined(SONY2FUJI_ENABLE_GLES)\na();\n#else\nb();\n#endif\n": 1,
            # Continuation lines and block comments.
            "#if defined(FOO) || \\\n    defined(SONY2FUJI_ENABLE_METAL)\na();\n#else\nb();\n#endif\n": 1,
            "/*\n#ifdef SONY2FUJI_ENABLE_METAL\n#else\n#endif\n*/\nint x;\n": 0,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(len(metal_only_branches(text)), expected)


if __name__ == "__main__":
    unittest.main()
