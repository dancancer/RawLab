import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("macos_config", ROOT / "scripts/release/macos_config.py")
config = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(config)


class ReleaseInputs(unittest.TestCase):
    def test_missing_model_pin_and_conflicting_signers_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary)
            (model / "manifest.json").write_text("{}")
            for name in ("raw.mlmodelc", "rgb.mlmodelc", "blind_rgb.mlmodelc"):
                (model / name).mkdir()
            env = dict(RAWLAB_RELEASE_VERSION="0.9.1", RAWLAB_RELEASE_BUILD="19",
                       RAWLAB_SPARKLE_PUBLIC_KEY=base64.b64encode(bytes(32)).decode(),
                       RAWLAB_UPDATE_CERTIFICATE_SHA256="a" * 64, RAWLAB_DUALDN_MODEL_DIR=str(model),
                       RAWLAB_DUALDN_MANIFEST_SHA256=hashlib.sha256(b"{}").hexdigest())
            self.assertEqual("19", config.configuration(env)["CFBundleVersion"])
            with self.assertRaises(ValueError): config.configuration(env | {"RAWLAB_UPDATE_TEAM_ID": "123456789A"})
            with self.assertRaises(ValueError): config.configuration(env | {"RAWLAB_DUALDN_MANIFEST_SHA256": "b" * 64})
            with self.assertRaises(ValueError): config.configuration(env | {"RAWLAB_UPDATE_CERTIFICATE_SHA256": ""})
            (model / "blind_rgb.mlmodelc").rmdir()
            with self.assertRaises(ValueError): config.configuration(env)

    @unittest.skipUnless(os.environ.get("RAWLAB_TEST_SPARKLE_BIN"), "requires the pinned local Sparkle tools")
    def test_appcast_and_archive_verify_with_public_key_and_reject_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); private = root / "private-key.txt"
            # Test-only key, never installed in the login keychain.
            source = 'import Foundation; import CryptoKit; let k=Curve25519.Signing.PrivateKey(); try Data(k.rawRepresentation.base64EncodedString().utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[1])); print(k.publicKey.rawRepresentation.base64EncodedString())'
            public = subprocess.check_output(["swift", "-e", source, str(private)], text=True).strip()
            private.chmod(0o600)
            app = root / "RawLab.app"; (app / "Contents").mkdir(parents=True)
            info = dict(CFBundleShortVersionString="0.9.1", CFBundleVersion="19", LSMinimumSystemVersion="14.0",
                        RawLabUpdateArchitecture="arm64", SURequireSignedFeed=True, SUPublicEDKey=public)
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            archive = root / "RawLab-Mac-0.9.1-arm64.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.write(app / "Contents/Info.plist", "RawLab.app/Contents/Info.plist")
            notes = root / "notes.txt"; notes.write_text("Update test")
            feed = root / "appcast-arm64.xml"
            subprocess.run(["python3", str(ROOT / "scripts/release/macos_appcast.py"), "--app", str(app), "--archive", str(archive),
                "--private-key", str(private), "--sparkle-bin", os.environ["RAWLAB_TEST_SPARKLE_BIN"], "--notes", str(notes),
                "--output", str(feed), "--arch", "arm64"], check=True)
            feed.write_bytes(feed.read_bytes().replace(b"Update test", b"Update evil"))
            rejected = subprocess.run(["swift", str(ROOT / "scripts/release/verify-sparkle.swift"), public, str(feed), "feed"], capture_output=True)
            self.assertNotEqual(0, rejected.returncode)


if __name__ == "__main__": unittest.main()
