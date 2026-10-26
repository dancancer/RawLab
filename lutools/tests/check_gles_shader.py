#!/usr/bin/env python3
"""Compile the actual assembled GLES photo shader without a GPU or Android runtime."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--validator', default=shutil.which('glslangValidator') or shutil.which('glslang'))
args = parser.parse_args()
if not args.validator:
    parser.error('glslangValidator is required for offline GLES validation')
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='rawlab-gles-shader-') as directory:
    output = Path(directory)
    exporter = output / ('shader-source.exe' if os.name == 'nt' else 'shader-source')
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-I', str(root/'src'), '-I', str(root/'include'),
                    str(root/'tests/gles_shader_source.cpp'), '-o', str(exporter)], check=True)
    shader = output/'photo.comp'
    with shader.open('wb') as stream:
        subprocess.run([str(exporter)], stdout=stream, check=True)
    subprocess.run([args.validator, '-S', 'comp', str(shader)], check=True)
print('PASS GLES photo shader and shared tone, grading and curve functions compile')
