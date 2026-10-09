#!/usr/bin/env python3
"""Run existing real-RAW gates on external fixtures; never download or bundle photos."""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from urllib.parse import urlparse


def run(command, log, timeout, env):
    started = time.monotonic()
    with log.open("w") as stream:
        stream.write("Command: " + repr(command) + "\n")
        stream.flush()
        try:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=timeout, env=env)
            code = result.returncode
            status = "PASS" if code == 0 else "FAIL"
        except subprocess.TimeoutExpired:
            code, status = None, "TIMEOUT"
            stream.write("\nTest exceeded timeout\n")
    return {"status": status, "exit_code": code,
            "seconds": round(time.monotonic() - started, 2), "log": str(log)}


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path,
                        default=Path(__file__).with_name("dpreview-raw-samples.json"))
    parser.add_argument("--samples", type=Path, required=True,
                        help="Directory containing original filenames from the manifest URLs")
    parser.add_argument("--build", type=Path, default=root / "lutools/build-macos")
    parser.add_argument("--app", type=Path,
                        default=root / "build/RawLab Mac.app/Contents/MacOS/RawLabMac")
    parser.add_argument("--output", type=Path, required=True,
                        help="New directory for this run (must not already exist)")
    parser.add_argument("--only", nargs="*", help="Run only these manifest IDs")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    entries = json.loads(args.manifest.read_text())["samples"]
    if args.only:
        unknown = set(args.only) - {row["id"] for row in entries}
        if unknown:
            parser.error("Unknown sample IDs: " + ", ".join(sorted(unknown)))
        entries = [row for row in entries if row["id"] in args.only]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    binaries = [args.build / name for name in
                ("raw_smoke", "white_balance_tests", "acceleration_tests")]
    binaries.append(args.app)
    for binary in binaries:
        if not binary.is_file():
            parser.error("Missing executable: " + str(binary))
    lut = root / "lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"
    report = {"platform": platform.platform(), "manifest": str(args.manifest.resolve()),
              "build": str(args.build.resolve()), "app": str(args.app.resolve()),
              "OMP_NUM_THREADS": os.environ.get("OMP_NUM_THREADS"), "samples": []}
    report_path = args.output / "results.json"
    for entry in entries:
        raw = args.samples.resolve() / Path(urlparse(entry["url"]).path).name
        out = args.output / entry["id"]
        out.mkdir()
        row = {**entry, "file": str(raw), "stages": {}}
        report["samples"].append(row)
        if not raw.is_file():
            row["stages"]["input"] = {"status": "MISSING"}
        else:
            row["bytes"] = raw.stat().st_size
            env = {**os.environ, "RAWTOOLS_TEST_ARTIFACTS": str(out / "proof")}
            commands = {
                "raw": [str(binaries[0].resolve()), str(raw),
                        *map(str, entry.get("expected_dimensions", []))],
                "white_balance": [str(binaries[1].resolve()), str(raw)],
                "mac_export": [str(args.app.resolve()), "--smoke", str(raw), str(out / "mac")],
            }
            if entry.get("gpu"):
                commands["cpu_metal"] = [str(binaries[2].resolve()), str(raw), str(lut)]
            for stage, command in commands.items():
                row["stages"][stage] = run(command, out / (stage + ".log"), args.timeout, env)
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                print(entry["id"], stage, row["stages"][stage]["status"], flush=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    return int(any(stage["status"] != "PASS" for row in report["samples"]
                   for stage in row["stages"].values()))


if __name__ == "__main__":
    raise SystemExit(main())
