#!/usr/bin/env python3
"""Replay the frozen P3 quality matrix through native CPU/Metal, not Python output."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import cv2
import numpy as np

import denoise_experiment_metrics as metrics
import denoise_p3 as p3
import run_denoise_p3_scenarios as matrix
from run_denoise_quality import sha256, write_json


def identity(source):
    return hashlib.sha256(source.tobytes()).hexdigest()


class NativeCase:
    def __init__(self, probe, probe_hash, directory, rendered, kind, modes):
        self.probe, self.directory, self.modes = probe, directory, modes
        self.probe_hash = probe_hash
        self.inputs, self.cache, self.batches, self.runs = {}, {}, [], []
        for scenario in rendered["scenarios"]:
            source = matrix.load(scenario, "off")
            self.inputs[identity(source)] = {"id": scenario["settings"]["id"],
                "path": scenario["buffers"]["off"]["path"], "width": source.shape[1], "height": source.shape[0]}
        amounts = list(np.linspace(0, 2, 17)) if kind == "edge" else [0, *matrix.AMOUNTS]
        self.run(list(self.inputs.values()), amounts)

    def run(self, inputs, amounts):
        if sha256(self.probe) != self.probe_hash:
            raise ValueError("native probe changed during replay")
        directory = self.directory / f"batch-{len(self.batches)}"
        request = directory.with_suffix(".json")
        write_json(request, {"output": str(directory), "inputs": inputs, "modes": self.modes, "amounts": amounts})
        result = subprocess.run([str(self.probe), str(request)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        if sha256(self.probe) != self.probe_hash:
            raise ValueError("native probe changed during replay")
        report = json.loads((directory / "result.json").read_text())
        expected = {(item["id"], mode, float(np.float32(amount))) for item in inputs for mode in self.modes for amount in amounts}
        if report["candidate"] != p3.CANDIDATE_ID or len(report["runs"]) != len(expected):
            raise ValueError("incomplete native report")
        observed = set()
        for run in report["runs"]:
            key = run["id"], run["mode"], run["amount"]
            if key in observed or key not in expected:
                raise ValueError("duplicate/unexpected native run")
            observed.add(key)
            positive = run["amount"] > 0
            if run["applied"] != positive or run["gpu_used"] != (positive and run["mode"] == "metal"):
                raise ValueError("native backend/zero bypass mismatch")
            value = run["buffer"]
            item = next(item for item in inputs if item["id"] == run["id"])
            if (value["shape"] != [item["height"], item["width"], 3] or value["space"] != "display_RGB" or
                    value["stage"] != "p3_sharpen" or value["dtype"] != "<f4"):
                raise ValueError("native buffer contract mismatch")
            path = Path(value["path"]).resolve()
            if not path.is_relative_to(directory.resolve()):
                raise ValueError("native buffer outside output")
            value["sha256"] = sha256(path)
            self.cache[key] = run
            self.runs.append(run)
        self.batches.append(directory)

    def call(self, source, amount, mode):
        item = self.inputs[identity(source)]
        key = item["id"], mode, float(np.float32(amount))
        if key not in self.cache:
            self.run([item], [float(amount)])
        run = self.cache[key]
        return np.asarray(metrics.load_buffer(run["buffer"])), {key: value for key, value in run.items() if key != "buffer"}

    def cleanup(self):
        write_json(self.directory / "native-runs.json", {"runs": self.runs, "buffers_removed": True})
        for directory in self.batches:
            for path in directory.rglob("*.f32"):
                path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True, help="Retained actual-display inputs with frozen-plan.json")
    parser.add_argument("--reference", type=Path, required=True, help="Frozen Python implementation; must match current reference")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--modes", nargs="+", choices=("cpu", "metal"), default=["cpu", "metal"])
    args = parser.parse_args()
    cv2.setNumThreads(6)
    if sha256(args.reference) != sha256(Path(p3.__file__)):
        raise ValueError("Python reference changed since freeze")
    plan = json.loads((args.matrix / "frozen-plan.json").read_text())
    if plan["gates"] != matrix.GATES:
        raise ValueError("quality gates changed")
    for path, digest in plan["lut_sha256"].items():
        if sha256(Path(path)) != digest:
            raise ValueError("LUT changed")
    args.output.mkdir(parents=True, exist_ok=False)
    failures, cases = [], []
    reference_hash, probe_hash = sha256(args.reference), sha256(args.probe)
    write_json(args.output / "frozen-plan.json", {**plan, "candidate": p3.CANDIDATE_ID,
        "candidate_sha256": reference_hash, "reference_sha256": reference_hash, "native_probe_sha256": probe_hash,
        "native_parity_max_abs": 2e-6, "modes": args.modes})
    for case in plan["cases"]:
        name, kind = case["id"], case["kind"]
        directory = args.output / name
        directory.mkdir()
        reports = []
        for label in ("source", "truth") if kind != "real_roi" else ("source",):
            base = args.matrix / name / label / "native"
            report = json.loads((base / "result.json").read_text())
            matrix.validate_render_report(report, case["shape"], plan["scenarios"], base)
            reports.append(report)
        rendered, truth = reports[0], reports[1] if len(reports) > 1 else None
        native = NativeCase(args.probe, probe_hash, directory, rendered, kind, args.modes)
        parity = []
        for scenario in rendered["scenarios"]:
            source = matrix.load(scenario, "off")
            for amount in (0, *matrix.AMOUNTS):
                expected = p3.noise_aware_sharpen(source, amount)[0]
                for mode in args.modes:
                    actual, _ = native.call(source, amount, mode)
                    error = float(np.max(np.abs(actual - expected)))
                    passed = actual.tobytes() == expected.tobytes() if amount == 0 else error <= 2e-6
                    parity.append({"scenario": scenario["settings"]["id"], "mode": mode, "amount": amount,
                                   "max_abs": error, "passed": passed})
                    if not passed:
                        failures.append([name, scenario["settings"]["id"], mode, amount, "python_parity", error])
        mode_reports = {}
        for mode in args.modes:
            rows, _ = matrix.evaluate_case(name, kind, rendered, truth,
                lambda source, amount: native.call(source, amount, mode))
            mode_reports[mode] = rows
            for row in rows:
                for check, passed in row["checks"].items():
                    if not passed:
                        failures.append([name, row["id"], mode, check])
                for method, measured in row["methods"].items():
                    for check, passed in measured["checks"].items():
                        if not passed:
                            failures.append([name, row["id"], mode, method, check])
        write_json(directory / "result.json", {"kind": kind, "parity": parity, "modes": mode_reports})
        native.cleanup()
        cases.append({"id": name, "result": str(directory / "result.json")})
        print(name, "MEASURED", "failures", len(failures), flush=True)
    if sha256(Path(p3.__file__)) != reference_hash or sha256(args.probe) != probe_hash:
        raise ValueError("reference/probe changed during replay")
    write_json(args.output / "results.json", {"status": "PASSED" if not failures else "FAILED_GATES",
        "cases": cases, "failures": failures, "modes": args.modes,
        "limits": ["CPU MAD and noise-map analysis is shared by both backends.",
                   "Real inputs here are measurement ROIs, not full-frame noise context or clean ground truth."]})
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
