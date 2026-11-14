# -*- coding: utf-8 -*-
"""Compile the production RAII blocks without stubbing unrelated render APIs."""

from pathlib import Path
import sys

source_dir = Path(__file__).resolve().parents[1] / "src" / "gpu"
blocks = []
for name in ("lut", "photo", "denoise"):
    source = (source_dir / f"gles_{name}.cpp").read_text(encoding="utf-8")
    start = source.index("struct Binding")
    end = source.index("\n};", start) + len("\n};")
    blocks.append(f"namespace {name}_binding {{\n{source[start:end]}\n}}\n")
Path(sys.argv[1]).write_text("".join(blocks), encoding="utf-8")
