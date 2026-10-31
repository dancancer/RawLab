"""把高光实验配置、实现和执行探针绑定到一次明确冻结的候选。"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import numpy as np

from scene_cache import digest
from sensor_highlights import neutralize_highlights
from detail_response import validate_profile as validate_detail_profile


def profile_hash(profile):
    return hashlib.sha256(json.dumps(profile, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def sources():
    return {name: digest(Path(__file__).with_name(name)) for name in
            ("sensor_highlights.py", "render_highlights.py", "decode_sensor.rs", "highlight_contract.py",
             "detail_response.py")}


def validate_profile(profile):
    if (profile.get("schema") != "rawlab-sensor-highlight-profile-v1"
            or profile.get("status") != "diagnostic-candidate-not-SPP-equivalent"
            or not isinstance(profile.get("camera_model"), str) or not profile["camera_model"]
            or not isinstance(profile.get("camera_serial"), str) or not profile["camera_serial"]):
        raise ValueError("Unsupported highlight profile schema or camera scope")
    neutralize_highlights(np.zeros((1, 1, 3), dtype=np.float32),
                          np.zeros((1, 1, 3), dtype=np.uint16), profile)
    if 'detail_response' in profile:
        validate_detail_profile(profile['detail_response'])


def freeze(profile, model, decoder, sensor_decoder):
    validate_profile(profile)
    return {"schema": "rawlab-highlight-contract-v1", "status": "frozen-experimental-candidate",
            "frozen_at_utc": datetime.now(timezone.utc).isoformat(),
            "profile": profile, "profile_sha256": profile_hash(profile),
            "model_path": str(Path(model).resolve()), "model_sha256": digest(model),
            "decoder_sha256": digest(decoder), "sensor_decoder_sha256": digest(sensor_decoder),
            "source_sha256": sources()}


def validate(contract, model, decoder, sensor_decoder):
    if (contract.get("schema") != "rawlab-highlight-contract-v1"
            or contract.get("status") != "frozen-experimental-candidate"):
        raise ValueError("A frozen highlight experiment contract is required")
    profile = contract.get("profile", {})
    validate_profile(profile)
    if (contract.get("profile_sha256") != profile_hash(profile)
            or contract.get("model_sha256") != digest(model)
            or contract.get("source_sha256") != sources()
            or contract.get("decoder_sha256") != digest(decoder)
            or contract.get("sensor_decoder_sha256") != digest(sensor_decoder)):
        raise ValueError("Highlight profile, model, implementation or decoder changed after freeze")
    return profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("profile", "model", "decoder", "sensor-decoder", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    from render_highlights import validate_model
    validate_model(json.loads(args.model.read_text()))
    contract = freeze(json.loads(args.profile.read_text()), args.model, args.decoder, args.sensor_decoder)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        json.dump(contract, stream, indent=2)
        stream.write("\n")
    args.output.chmod(0o444)
    print(json.dumps({"contract": str(args.output), "sha256": digest(args.output)}))


if __name__ == "__main__":
    main()
