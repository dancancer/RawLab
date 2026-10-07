import json
import os
from pathlib import Path
import shutil
import tempfile

import numpy as np
import PyOpenColorIO as ocio

from . import __version__
from .color import ColorSpaces, apply_processor
from .pipeline import LUTPipeline, file_processor
from .dcp import DCPProfile
from .native import read_native


class BakingError(ValueError):
    def __init__(self, report):
        self.report = report
        super().__init__(f"Sampled error {report['error']['max']:.6f} exceeds {report['max_error']:.6f}; "
                         "increase --size or explicitly use --allow-approximation")


def _compact(value):
    return "".join(c.lower() for c in value if c.isascii() and c.isalnum())


def _cube_info(path):
    comments, keywords = {}, {}
    metadata = None
    native_safe, rows = True, 0
    with path.open(encoding="utf-8-sig") as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                key, separator, value = line[1:].partition(":")
                if separator:
                    comments[_compact(key)] = _compact(value)
                    if _compact(key) == "rawlab":
                        metadata = json.loads(value)
                continue
            key, *values = line.split()
            if key in ("TITLE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX"):
                if key in keywords and key != "TITLE":
                    native_safe = False
                keywords[key] = values
            else:
                try:
                    numbers = [float(v) for v in [key, *values][:3]]
                    native_safe &= len(numbers) == 3 and all(np.isfinite(numbers))
                    rows += 1
                except ValueError:
                    native_safe = False
    size = int(keywords.get("LUT_3D_SIZE", [0])[0])
    minimum = [float(v) for v in keywords.get("DOMAIN_MIN", [0, 0, 0])]
    maximum = [float(v) for v in keywords.get("DOMAIN_MAX", [1, 1, 1])]
    valid_domain = (len(minimum) == len(maximum) == 3 and
                    all(np.isfinite(minimum + maximum)) and
                    all(a < b for a, b in zip(minimum, maximum)))
    gamma = comments.get("gamma", "")
    input_transfer, _, output = gamma.partition("to")
    log_transfers = ("flog", "flog2", "flog2c")
    expected_gamut = "fgamutc" if input_transfer == "flog2c" else "fgamut"
    native = (native_safe and 2 <= size <= 256 and rows == size ** 3 and valid_domain
              and input_transfer in log_transfers and bool(output)
              and comments.get("gamut") == expected_gamut + "toiturbt709")
    output_transfer = output if output in log_transfers else "display-srgb"
    contract = ({"input_transfer": input_transfer, "input_gamut": expected_gamut,
                 "output_transfer": output_transfer, "output_gamut": "bt709",
                 "cpu_only": False}
                if native else None)
    canonical = (native and input_transfer == "flog2" and output_transfer == "display-srgb"
                 and comments.get("outputtransfer", "srgb") == "srgb")
    return {"canonical": bool(canonical), "size": size or None, "domain_min": minimum,
            "domain_max": maximum, "metadata": metadata,
            "native_photo_compatible": bool(native), "photo_contract": contract}


def inspect_source(source):
    source = Path(source)
    if not source.is_file():
        raise FileNotFoundError(source)
    if source.suffix.lower() == ".dcp":
        return {"source": source.name, **DCPProfile.read(source).describe()}
    if source.suffix.lower() == ".rlook":
        return {"source": source.name, "format": "rlook", "canonical": False,
                "metadata": read_native(source)["metadata"]}
    file_processor(source)
    info = {"source": source.name, "format": source.suffix.lower().lstrip("."), "canonical": False}
    if source.suffix.lower() == ".cube":
        info.update(_cube_info(source))
    return info


def validation_samples():
    rng = np.random.default_rng(20261003)
    axis = np.linspace(0, 1, 17)
    mesh = np.meshgrid(axis, axis, axis, indexing="ij")
    domain = np.concatenate([rng.random((4096, 3)), np.stack(mesh, axis=-1).reshape(-1, 3)])
    gray = np.repeat(np.linspace(0, 1, 513)[:, None], 3, axis=1)
    scene = rng.random((4096, 3)) * 2 ** rng.uniform(-10, 6, (4096, 1))
    scene = ColorSpaces().convert(scene, "linear-srgb", "flog2-fgamut")
    return {"domain": domain, "gray": gray, "scene": scene}


def measure_error(evaluate, serialized_cube):
    reader = file_processor(serialized_cube, "linear")
    cohorts, errors = {}, []
    for label, points in validation_samples().items():
        actual = apply_processor(reader, points)
        expected = evaluate(points)
        error = np.abs(actual - expected)
        if not np.all(np.isfinite(error)):
            raise ValueError("Validation produced nonfinite error")
        cohorts[label] = {"samples": len(points), "max": float(error.max()),
                          "mean": float(error.mean()), "p99": float(np.quantile(error, .99))}
        errors.append(error.ravel())
    error = np.concatenate(errors)
    return {"max": float(error.max()), "mean": float(error.mean()),
            "p99": float(np.quantile(error, .99)), "cohorts": cohorts,
            "measurement": "sampled absolute display-sRGB channel error, not a global bound"}


def _write_cube(path, evaluate, size):
    axis = np.linspace(0, 1, size)
    g, r = np.meshgrid(axis, axis, indexing="ij")
    plane = np.stack([r.ravel(), g.ravel(), np.zeros(size * size)], axis=1)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write('TITLE "RawLab prepared look"\n#Gamma:F-Log2 to RawLab Prepared\n'
                     '#Gamut:F-Gamut to ITU-R BT.709\n#OutputTransfer:sRGB\n')
        stream.write(f"LUT_3D_SIZE {size}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n")
        for b in axis:
            plane[:, 2] = b
            values = evaluate(plane)
            if values.shape != plane.shape or not np.all(np.isfinite(values)):
                raise ValueError("LUT composition must produce finite RGB triples")
            np.savetxt(stream, values, fmt="%.9g")


def prepare(source, destination, contract=None, *, size=65, max_error=.02,
            allow_approximation=False, force=False, dcp_exposure=True):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Source and destination must be different files")
    if destination.exists() and source.exists() and os.path.samefile(source, destination):
        raise ValueError("Source and destination must be different files")
    if destination.suffix.lower() != ".cube":
        raise ValueError("Destination must have a .cube extension")
    if destination.exists() and not force:
        raise FileExistsError(f"Destination exists: {destination}; use --force to replace it")
    if type(size) is not int or not 2 <= size <= 129:
        raise ValueError("size must be an integer from 2 to 129")
    if not np.isfinite(max_error) or max_error < 0:
        raise ValueError("max_error must be finite and nonnegative")
    info = inspect_source(source)
    is_dcp = info["format"] == "dcp"
    if is_dcp and contract is not None:
        raise ValueError("DCP uses its own D65 profile input adapter, not a generic RGB LUT contract")
    passthrough = contract is None and info["canonical"]
    if not passthrough and not is_dcp and contract is None:
        if info.get("native_photo_compatible"):
            raise ValueError("Source supports direct native import; canonical display preparation still requires --contract")
        raise ValueError("Source has no canonical color contract; supply --contract with explicit input/output")
    if is_dcp:
        profile = DCPProfile.read(source)
        spaces = ColorSpaces()

        def evaluate(rgb):
            linear = spaces.convert(rgb, "flog2-fgamut", "linear-srgb")
            return profile.evaluate(linear, apply_exposure=dcp_exposure)
    elif not passthrough:
        evaluate = LUTPipeline(source, contract).evaluate
    descriptor, name = tempfile.mkstemp(prefix=".rawlab-lut-", suffix=".cube", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        if passthrough:
            shutil.copyfile(source, temporary)
            report = {"version": __version__, "mode": "passthrough", "source": source.name,
                      "size": info["size"], "resampling": False}
        else:
            _write_cube(temporary, evaluate, size)
            error = measure_error(evaluate, temporary)
            report = {"version": __version__, "mode": "dcp-look" if is_dcp else "baked", "source": source.name,
                      "size": size, "error": error, "ocio_version": ocio.__version__,
                      "max_error": max_error, "within_tolerance": error["max"] <= max_error,
                      "allow_approximation": allow_approximation}
            if is_dcp:
                report["dcp"] = {**profile.describe(), "apply_profile_exposure": dcp_exposure,
                                 "exposure_method": "linear EV before look; not Adobe exposure-tone emulation"}
            else:
                report["contract"] = contract.to_dict()
                if contract.ocio:
                    report["contract"]["ocio"]["config"] = Path(contract.ocio["config"]).name
            if not report["within_tolerance"] and not allow_approximation:
                raise BakingError(report)
            with temporary.open("a", encoding="utf-8") as stream:
                stream.write("#RawLab:" + json.dumps(report, ensure_ascii=True, separators=(",", ":")) + "\n")
        if force:
            os.replace(temporary, destination)
        else:
            os.link(temporary, destination)
        return report
    finally:
        temporary.unlink(missing_ok=True)
