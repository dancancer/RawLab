#!/usr/bin/env python3
"""Validate public release inputs and write them into an already-built app plist."""
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import re
import sys


def configuration(env=os.environ):
    def required(name):
        value = env.get(name, "").strip()
        if not value:
            raise ValueError(f"Missing {name}")
        return value
    version = required("RAWLAB_RELEASE_VERSION")
    build = required("RAWLAB_RELEASE_BUILD")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdecimal() or int(build) < 1:
        raise ValueError("Release version/build is invalid")
    key = required("RAWLAB_SPARKLE_PUBLIC_KEY")
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Sparkle public key must contain 32 bytes")
    certificate = env.get("RAWLAB_UPDATE_CERTIFICATE_SHA256", "").strip().lower()
    team = env.get("RAWLAB_UPDATE_TEAM_ID", "").strip()
    if bool(certificate) == bool(team):
        raise ValueError("Configure exactly one signing mode: certificate SHA-256 or Developer ID Team ID")
    if certificate and not re.fullmatch(r"[a-f0-9]{64}", certificate):
        raise ValueError("Invalid signing certificate SHA-256")
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid Developer ID Team ID")
    model = Path(required("RAWLAB_DUALDN_MODEL_DIR"))
    expected = required("RAWLAB_DUALDN_MANIFEST_SHA256").lower()
    if hashlib.sha256((model / "manifest.json").read_bytes()).hexdigest() != expected:
        raise ValueError("DualDn manifest SHA-256 does not match the release input")
    for resource in ("raw.mlmodelc", "rgb.mlmodelc", "blind_rgb.mlmodelc"):
        if not (model / resource).is_dir():
            raise ValueError(f"Release package is missing native GPU model {resource}")
    values = dict(CFBundleShortVersionString=version, CFBundleVersion=build, SUPublicEDKey=key,
                  SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                  SUSignedFeedFailureExpirationInterval=0)
    values["RawLabUpdateCertificateSHA256" if certificate else "RawLabUpdateTeamID"] = certificate or team
    return values


def main():
    values = configuration()
    if sys.argv[1:] == ["validate"]:
        return
    if len(sys.argv) != 4 or sys.argv[1] != "configure" or sys.argv[3] not in ("arm64", "x86_64"):
        raise ValueError("Usage: macos_config.py validate | configure Info.plist arm64|x86_64")
    path = Path(sys.argv[2]); arch = sys.argv[3]
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    info.pop("RawLabUpdateCertificateSHA256", None); info.pop("RawLabUpdateTeamID", None)
    info.update(values, RawLabUpdateArchitecture=arch,
                SUFeedURL=f"https://github.com/dancancer/RawLab/releases/latest/download/appcast-{arch}.xml")
    with path.open("wb") as stream:
        plistlib.dump(info, stream)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
