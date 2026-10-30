"""独立的传感器高光诊断入口；保持 v2 基础模型不变，不读取 SPP 参考图。"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import numpy as np

from calibration import rotate_saved
from detail_response import apply_detail
from evaluation_contract import payload_hash, source_hashes
from highlight_contract import validate as validate_contract
from render_v2 import render_scene, validate_settings
from saved_settings import read_saved_settings
from scene_cache import DECODER_REVISION, decode_fresh, digest
from sensor_highlights import neutralize_highlights, validate_camera


def validate_model(model):
    frozen = model.get("freeze", {})
    if (frozen.get("status") != "frozen"
            or frozen.get("model_payload_sha256") != payload_hash(model)
            or frozen.get("source_sha256") != source_hashes()):
        raise ValueError("The v2 model or its rendering sources differ from the frozen baseline")


def decode_pair(decoder, sensor_decoder, raw, settings, profile, work):
    import tifffile
    raw, work = Path(raw).resolve(), Path(work)
    before = digest(raw)
    scene, metadata = decode_fresh(decoder, raw, work / "scene", settings)
    sensor_dir = work / "sensor"
    subprocess.run([str(Path(sensor_decoder).resolve()), str(raw), str(sensor_dir)], check=True)
    protocol = json.loads((sensor_dir / "sensor-protocol.json").read_text())
    if (protocol.get("schema") != "rawlab-sensor-evidence-v1"
            or protocol.get("decoder_revision") != DECODER_REVISION
            or protocol.get("source_path") != str(raw)
            or protocol.get("active_area_cropped") is not True
            or protocol.get("orientation_applied") is not False
            or protocol.get("processing") != "unprocessed"):
        raise ValueError("Unexpected sensor evidence protocol")
    validate_camera((sensor_dir / "sensor-metadata.txt").read_text(), profile)
    sensor_path = sensor_dir / "sensor.tif"
    sensor = tifffile.imread(sensor_path)
    if sensor.dtype != np.uint16 or sensor.shape != scene.shape:
        raise ValueError("Sensor TIFF is not aligned with the full-resolution scene")
    if digest(raw) != before or metadata["source_sha256"] != before:
        raise ValueError("RAW changed between scene and sensor decoding")
    metadata.update(sensor_sha256=digest(sensor_path),
                    sensor_decoder_sha256=digest(sensor_decoder),
                    sensor_protocol=protocol)
    return scene, sensor, metadata


def write_output(output, rendered, icc, report):
    import tifffile
    output = Path(output)
    evidence = Path(str(output) + ".json")
    output.parent.mkdir(parents=True, exist_ok=True)
    # 两份文件都写完整后才发布；链接的独占创建保护已有输出，普通失败回滚本次链接。
    with tempfile.TemporaryDirectory(prefix=".rawlab-highlight-", dir=output.parent) as directory:
        staged_image, staged_evidence = Path(directory) / "image.tif", Path(directory) / "evidence.json"
        tifffile.imwrite(staged_image, np.rint(np.clip(rendered, 0, 1) * 65535).astype(np.uint16),
                         photometric="rgb", metadata=None,
                         # 对齐本实验 SPP 原尺寸导出的物理分辨率；不改变像素尺寸。
                         resolution=(180, 180), resolutionunit="INCH",
                         software="RawLab X3F sensor highlight diagnostic",
                         extratags=[(34675, "B", len(icc), icc, False)] if icc else [])
        report = {**report, "output_sha256": digest(staged_image)}
        staged_evidence.write_text(json.dumps(report, indent=2) + "\n")
        linked = []
        try:
            for source, destination in ((staged_image, output), (staged_evidence, evidence)):
                os.link(source, destination)
                linked.append((source, destination))
        except OSError:
            for source, destination in linked:
                if destination.exists() and os.path.samefile(source, destination):
                    destination.unlink()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("decoder", "sensor-decoder", "model", "contract"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    evidence_path = Path(str(args.output) + ".json")
    if args.output.exists() or evidence_path.exists():
        raise ValueError("Output or evidence file already exists")
    model = json.loads(args.model.read_text())
    validate_model(model)
    contract = json.loads(args.contract.read_text())
    profile = validate_contract(contract, args.model, args.decoder, args.sensor_decoder)
    settings = read_saved_settings(args.raw)
    validate_settings(settings)
    with tempfile.TemporaryDirectory(prefix="rawlab-x3f-highlight-") as work:
        scene, sensor, metadata = decode_pair(args.decoder, args.sensor_decoder, args.raw,
                                              settings, profile, work)
        corrected, confidence = neutralize_highlights(scene, sensor, profile)
        rendered = render_scene(rotate_saved(corrected, settings.rotation), settings,
                                model["base"], model["controls"], model["fill"])
        if 'detail_response' in profile:
            rendered = apply_detail(np.clip(rendered, 0, 1), profile['detail_response'])
    from PIL import ImageCms
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    report = {"role": "diagnostic-candidate-not-independent-validation",
              "model_path": str(args.model.resolve()), "model_sha256": digest(args.model),
              "contract": contract, "contract_sha256": digest(args.contract),
              "profile_sha256": contract["profile_sha256"],
              "profile": profile, "source": metadata, "settings": settings.to_dict(),
              "shape": list(rendered.shape), "affected_fraction": float(np.mean(confidence > 0)),
              "fully_neutral_fraction": float(np.mean(confidence == 1)),
              "experiment_source_sha256": {name: digest(Path(__file__).with_name(name)) for name in
                                           ("sensor_highlights.py", "render_highlights.py", "decode_sensor.rs", "highlight_contract.py", "detail_response.py")}}
    write_output(args.output, rendered, icc, report)
    print(json.dumps({"output": str(args.output), "evidence": str(evidence_path),
                      "affected_fraction": report["affected_fraction"]}))


if __name__ == "__main__":
    main()
