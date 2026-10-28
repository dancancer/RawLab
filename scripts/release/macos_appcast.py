#!/usr/bin/env python3
"""Create one architecture's signed GitHub appcast; never upload or publish it."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RAWLAB = "https://github.com/dancancer/RawLab/updates"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("rawlab", RAWLAB)


def main():
    parser = argparse.ArgumentParser()
    for name in ("app", "archive", "private-key", "sparkle-bin", "notes", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    if info.get("RawLabUpdateArchitecture") != args.arch or not info.get("SURequireSignedFeed"):
        raise ValueError("App is missing release update configuration")
    with zipfile.ZipFile(args.archive) as archive:
        plists = [name for name in archive.namelist() if name.count("/") == 2 and name.endswith(".app/Contents/Info.plist")]
        if len(plists) != 1 or plistlib.loads(archive.read(plists[0])) != info:
            raise ValueError("Archive metadata does not match the signed app")
    signer = args.sparkle_bin / "sign_update"
    signature = subprocess.check_output([str(signer), "--ed-key-file", str(args.private_key), "-p", str(args.archive)], text=True).strip()
    verifier = Path(__file__).with_name("verify-sparkle.swift")
    subprocess.run(["swift", str(verifier), info["SUPublicEDKey"], str(args.archive), "archive", signature], check=True)
    root = ET.Element("rss", version="2.0"); channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "RawLab Mac"
    item = ET.SubElement(channel, "item")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    ET.SubElement(item, "title").text = f"RawLab {version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "description").text = args.notes.read_text(encoding="utf-8")
    with args.archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    ET.SubElement(item, "enclosure", {"url": f"https://github.com/dancancer/RawLab/releases/download/v{version}/{args.archive.name}",
        "length": str(args.archive.stat().st_size), "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": signature,
        f"{{{RAWLAB}}}architecture": args.arch, f"{{{RAWLAB}}}sha256": digest})
    with args.output.open("xb") as stream:
        stream.write(ET.tostring(root, encoding="utf-8", xml_declaration=True))
    subprocess.run([str(signer), "--ed-key-file", str(args.private_key), str(args.output)], check=True)
    subprocess.run(["swift", str(verifier), info["SUPublicEDKey"], str(args.output), "feed"], check=True)


if __name__ == "__main__":
    main()
