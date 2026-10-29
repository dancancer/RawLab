#!/usr/bin/env python3
"""核对真机 UI 读回的四份 Photos 原始资源；截图或成功提示不能替代此门槛。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def verify(attachments: Path, cli: Path, output: Path) -> list[dict]:
    manifest = json.loads((attachments / "manifest.json").read_text())
    entries = [item for suite in manifest for item in suite["attachments"]]
    output.mkdir()
    report = []
    for source, size in [("Android", (4080, 3072)), ("iPhone", (3024, 4032))]:
        for mode in ["sdr", "hdr"]:
            prefix = f"device-{source}-{mode}-photos-original"
            matches = [item for item in entries if item["suggestedHumanReadableName"].startswith(prefix)
                       and item["suggestedHumanReadableName"].endswith(".jpg")]
            assert len(matches) == 1, f"Expected one actual Photos resource: {prefix}"
            name = matches[0]["exportedFileName"]
            assert Path(name).name == name, "Unexpected attachment path"
            data = (attachments / name).read_bytes()
            assert data[:2] == b"\xff\xd8" and data[-2:] == b"\xff\xd9", prefix
            photo = output / f"{source}-{mode}.jpg"
            photo.write_bytes(data)
            result = json.loads(subprocess.check_output([str(cli), "--info", str(photo), "--json"]))
            assert result["ok"], result
            info = result["result"]
            assert (info["identified_size"]["width"], info["identified_size"]["height"]) == size, info
            assert info["identified_size"]["orientation"] == 1, info
            if mode == "hdr":
                assert info["input_type"] == "hdr_raster" and info["hdr_protocol"] == 4, info
                assert info["bits_per_component"] == 32 and info["content_headroom"] > 1, info
            else:
                assert info["input_type"] == "raster" and info["bits_per_component"] == 8, info
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(photo), "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"], check=True)
            report.append({"name": photo.name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "info": info})
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--attachments", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert args.cli.is_file(), args.cli
    assert shutil.which("ffmpeg"), "Independent primary-image decoding requires FFmpeg"
    for row in verify(args.attachments, args.cli, args.output):
        print(f"PASS Photos original: {row['name']}, {row['info']['input_type']}, {row['bytes']} bytes")
