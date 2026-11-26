#!/usr/bin/env python3
"""Static guard against HLSL/GLSL/MSL reserved keyword collisions in shared shader bodies."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


GPU_DIR = Path(__file__).resolve().parents[1] / "src" / "gpu"

# Keywords across HLSL (cs_5_0), GLSL ES 3.10, and Metal that must never be used
# as user identifiers in cross-dialect shared shader templates/macros.
FORBIDDEN_SHADER_IDENTIFIERS = frozenset({
    # HLSL interpolation / geometry / type / parameter modifiers
    "linear", "centroid", "nointerpolation", "noperspective", "sample",
    "point", "line", "lineadj", "triangle", "triangleadj",
    "in", "out", "inout", "half", "matrix", "vector", "texture", "sampler",
    "snorm", "unorm", "precise", "groupshared", "shared", "uniform",
    # GLSL ES 3.10 qualifiers / reserved words
    "attribute", "varying", "buffer", "coherent", "restrict", "readonly", "writeonly",
    "flat", "smooth", "patch", "discard", "input", "output", "filter",
    # Metal address space / shader qualifiers
    "device", "constant", "thread", "threadgroup", "kernel", "vertex", "fragment",
})

SHARED_SHADER_BODIES = {
    "photo_log_shader.h": [
        r"#define\s+RAWLAB_LOG_FUNCTIONS_BODY\s*\\\n(.*?)\n\n",
    ],
    "photo_tone_shader.h": [
        r"#define\s+RAWLAB_HIGHLIGHTS_SHADOWS_BODY\s*\\\n(.*?)\n\n",
        r'R"shader\((.*?)\)shader"',
    ],
    "photo_color_grading_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
    "photo_tone_curve_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
    "photo_film_optics_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
    "photo_color_science_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
    "dcp_look_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
    "photo_spatial_shader.h": [
        r'R"shader\((.*?)\)shader"',
    ],
}


def _strip_preprocessor_and_comments(text: str) -> str:
    text = re.sub(r"//.*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(lines)


def find_reserved_shader_identifiers(source: str) -> list[str]:
    cleaned = _strip_preprocessor_and_comments(source)
    tokens = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", cleaned))
    return sorted(tokens & FORBIDDEN_SHADER_IDENTIFIERS)


class SharedShaderKeywordTests(unittest.TestCase):
    def test_detector_flags_hlsl_reserved_interpolation_modifier(self) -> None:
        self.assertEqual(
            find_reserved_shader_identifiers("float flog2(float linear) { return linear; }"),
            ["linear"],
        )

    def test_shared_shader_bodies_avoid_dialect_reserved_keywords(self) -> None:
        for filename, patterns in SHARED_SHADER_BODIES.items():
            path = GPU_DIR / filename
            content = path.read_text(encoding="utf-8")
            matched_blocks = 0
            for pattern in patterns:
                for match in re.finditer(pattern, content, flags=re.DOTALL):
                    matched_blocks += 1
                    collisions = find_reserved_shader_identifiers(match.group(1))
                    self.assertEqual(
                        collisions,
                        [],
                        f"{filename} contains reserved shader keyword(s): {collisions}",
                    )
            self.assertGreater(matched_blocks, 0, f"No shader blocks matched in {filename}")


if __name__ == "__main__":
    unittest.main()
