"""Collect the locked Rust dependency notices for app packaging."""
import argparse
import json
from pathlib import Path
import subprocess
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cargo", required=True)
parser.add_argument("--manifest", required=True)
parser.add_argument("--target", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
metadata = json.loads(subprocess.check_output([
    args.cargo, "metadata", "--format-version", "1", "--locked", "--offline",
    "--manifest-path", args.manifest, "--filter-platform", args.target,
], text=True, encoding="utf-8"))
sections = ["RawLab X3F renderer dependency notices\n\n"
            "x3fuse-core is pinned to 00f9ef206a2d629bca35ceead4b3951833b85d3d.\n"
            "The list includes build dependencies for completeness.\n"]
for package in sorted(metadata["packages"], key=lambda value: value["name"]):
    if package["name"] == "rawlab-x3f":
        continue
    root = Path(package["manifest_path"]).parent
    search = [root]
    if package["name"] in ("x3f-core", "x3f-sys"):
        search.append(root.parent.parent)
    paths = set()
    for directory in search:
        for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "NOTICE*"):
            paths.update(p for p in directory.glob(pattern) if p.is_file())
    if package.get("license_file"):
        paths.add(root / package["license_file"])
    if not paths and package["name"] in ("zune-core", "zune-jpeg"):
        notice = Path(__file__).with_name("licenses") / f"{package['name']}-{package['version']}-LICENSE.md"
        if notice.is_file():
            paths.add(notice)
    if not paths:
        raise SystemExit(f"Missing license text for {package['name']} {package['version']}")
    sections.append(f"\n{package['name']} {package['version']} ({package.get('license', '')})\n")
    for path in sorted(paths):
        sections.append(f"\n{path.name}\n{path.read_text(encoding='utf-8', errors='replace')}\n")
Path(args.output).write_text("".join(sections), encoding="utf-8")
# 静态链接还包含 Rust 标准库；使用实际编译工具链的原始说明。
sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True, encoding="utf-8").strip())
rust_docs = sysroot / "share/doc/rust"
copyright_file = rust_docs / "COPYRIGHT-library.html"
if not copyright_file.is_file():
    raise SystemExit("Rust runtime notices are missing; install rustup component rust-docs")
destination = Path(args.output).with_name("x3f-rust-licenses")
destination.mkdir(exist_ok=True)
shutil.copy2(copyright_file, destination / copyright_file.name)
shutil.copytree(rust_docs / "licenses", destination / "licenses", dirs_exist_ok=True)
