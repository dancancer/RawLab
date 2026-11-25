"""Drive upload-draft-release.sh against a fake gh: empty draft, bounded parallel retries, API size/sha256 gate."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/upload-draft-release.sh"
VERSION = "9.8.7"
ASSETS = [
    f"RawLab-Mac-{VERSION}-arm64.zip", f"RawLab-Mac-{VERSION}-x86_64.zip",
    "RawLab.Desktop-stable-Setup.exe", f"RawLab.Desktop-{VERSION}-stable-full.nupkg",
    f"RawLab-Windows-{VERSION}-x64.zip", f"RawLab-Android-{VERSION}.apk",
    f"RawLab-iOS-{VERSION}-unsigned.ipa", f"RawLab-{VERSION}-source.tar.gz",
    "appcast-arm64.xml", "appcast-x86_64.xml", "windows-stable.json", "BUILD-PROVENANCE.json",
]

# State lives in FAKE_GH_STATE: release.json (draft flag), assets/<name>.json, calls.log,
# active/ (in-flight uploads) and concurrency.log (in-flight count seen by each upload).
FAKE_GH = r'''
import hashlib, json, os, sys, time
from pathlib import Path
state = Path(os.environ["FAKE_GH_STATE"]); args = sys.argv[1:]
with (state / "calls.log").open("a") as log:
    log.write(json.dumps(args) + "\n")
release = state / "release.json"; assets = state / "assets"; assets.mkdir(exist_ok=True)
def opt(name):
    return args[args.index(name) + 1] if name in args else None
if args[:2] == ["release", "view"]:
    if not release.exists():
        print(f"release not found", file=sys.stderr); sys.exit(1)
    data = json.loads(release.read_text())
    print({"isDraft": "true" if data["draft"] else "false", "databaseId": "4242"}[opt("--json")])
elif args[:2] == ["release", "create"]:
    release.write_text(json.dumps({"draft": "--draft" in args, "tag": args[2]}))
elif args[:2] == ["release", "upload"]:
    path = Path(args[3]); name = path.name
    active = state / "active"; active.mkdir(exist_ok=True)
    marker = active / f"{name}.{os.getpid()}"; marker.touch()
    time.sleep(0.15)
    with (state / "concurrency.log").open("a") as log:
        log.write(f"{len(list(active.iterdir()))}\n")
    marker.unlink()
    attempts = state / f"attempts-{name}"
    count = int(attempts.read_text()) + 1 if attempts.exists() else 1
    attempts.write_text(str(count))
    fail = dict(item.split("=") for item in os.environ.get("FAKE_FAIL", "").split(",") if item)
    if count <= int(fail.get(name, 0)):
        print(f"HTTP 502: upload of {name} interrupted", file=sys.stderr); sys.exit(1)
    data = path.read_bytes()
    digest = "sha256:" + hashlib.sha256(data).hexdigest()
    if name == os.environ.get("FAKE_CORRUPT"):
        digest = "sha256:" + "0" * 64
    entry = {"name": name, "size": len(data), "state": "uploaded", "digest": digest}
    if os.environ.get("FAKE_NO_DIGEST"):
        entry.pop("digest")
    (assets / f"{name}.json").write_text(json.dumps(entry))
elif args[0] == "api":
    assert args[1] == "repos/dancancer/RawLab/releases/4242/assets?per_page=100", args
    print(json.dumps([json.loads(p.read_text()) for p in sorted(assets.glob("*.json"))]))
else:
    print(f"unexpected fake gh call: {args}", file=sys.stderr); sys.exit(97)
'''


class UploadDraftReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rawlab upload ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.dist = self.root / "dist"; self.dist.mkdir()
        for index, name in enumerate(ASSETS):
            (self.dist / name).write_bytes(f"{name}\n".encode() * (index + 1))
        self.write_sums()
        self.notes = self.root / "notes.md"; self.notes.write_text("Release notes\n", encoding="utf-8")
        self.state = self.root / "state"; self.state.mkdir()
        self.gh = self.root / "gh"
        self.gh.write_text(f"#!{sys.executable}\n{FAKE_GH}")
        self.gh.chmod(0o755)

    def write_sums(self):
        lines = [f"{hashlib.sha256((self.dist / n).read_bytes()).hexdigest()}  {n}" for n in ASSETS]
        (self.dist / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_script(self, *extra, jobs="3", attempts="3", **env):
        environment = {**os.environ, "GH": str(self.gh), "GH_TOKEN": "test-token", "FAKE_GH_STATE": str(self.state),
                       "RAWLAB_UPLOAD_BACKOFF": "0", "TMPDIR": str(self.root), **env}
        command = ["/bin/bash", str(SCRIPT), "--version", VERSION, "--dist", str(self.dist),
                   "--notes-file", str(self.notes), "--jobs", jobs, "--attempts", attempts, *extra]
        return subprocess.run(command, env=environment, capture_output=True, text=True)

    def calls(self):
        log = self.state / "calls.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def assertNeverPublished(self):
        for call in self.calls():
            self.assertNotEqual(call[:2], ["release", "edit"], "the script must never publish the draft")
        release = self.state / "release.json"
        if release.exists():
            self.assertTrue(json.loads(release.read_text())["draft"])

    def test_empty_draft_then_bounded_parallel_upload_and_13_of_13_api_verification(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        creates = [c for c in self.calls() if c[:2] == ["release", "create"]]
        self.assertEqual(len(creates), 1)
        self.assertIn("--draft", creates[0]); self.assertIn("--verify-tag", creates[0])
        self.assertFalse([a for a in creates[0] if a.startswith(str(self.dist))], "the draft must be created empty")
        uploads = [c for c in self.calls() if c[:2] == ["release", "upload"]]
        self.assertEqual(sorted(Path(c[3]).name for c in uploads), sorted(ASSETS + ["SHA256SUMS.txt"]))
        self.assertTrue(all("--clobber" in c for c in uploads))
        peak = max(int(n) for n in (self.state / "concurrency.log").read_text().split())
        self.assertGreaterEqual(peak, 2, "uploads must overlap")
        self.assertLessEqual(peak, 3, "uploads must respect --jobs")
        self.assertIn("local: 13/13 assets present, SHA256SUMS.txt 12/12 OK", result.stdout)
        self.assertIn("remote: 13/13 assets match local size and sha256", result.stdout)
        self.assertNeverPublished()

    def test_transient_upload_failures_are_retried_until_success(self):
        apk = f"RawLab-Android-{VERSION}.apk"
        result = self.run_script(FAKE_FAIL=f"{apk}=2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.state / f"attempts-{apk}").read_text(), "3")
        self.assertIn(f"retry {apk}: attempt 1/3 failed", result.stderr)
        self.assertIn(f"uploaded {apk} (attempt 3/3)", result.stdout)

    def test_exhausted_retries_name_the_asset_and_leave_the_draft_unpublished(self):
        nupkg = f"RawLab.Desktop-{VERSION}-stable-full.nupkg"
        result = self.run_script(FAKE_FAIL=f"{nupkg}=99")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"error: upload {nupkg} failed after 3 attempt(s)", result.stderr)
        self.assertIn("HTTP 502", result.stderr)
        self.assertIn(f"error:   {nupkg}", result.stderr)
        self.assertFalse([c for c in self.calls() if c[0] == "api"], "verification must not run after failed uploads")
        self.assertNeverPublished()
        # Rerunning resumes on the same draft without creating another one.
        retry = self.run_script()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertIn("reusing existing draft v9.8.7", retry.stdout)
        self.assertEqual(len([c for c in self.calls() if c[:2] == ["release", "create"]]), 1)

    def test_remote_digest_mismatch_or_missing_digest_fails_closed(self):
        for env, message in (({"FAKE_CORRUPT": "windows-stable.json"}, "windows-stable.json: digest sha256:000"),
                             ({"FAKE_NO_DIGEST": "1"}, "API returned no digest; cannot verify SHA-256")):
            with self.subTest(env=env):
                result = self.run_script(**env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertIn("failed API verification; do not publish it", result.stderr)
                self.assertNeverPublished()

    def test_local_dist_problems_stop_before_any_github_write(self):
        cases = {
            "missing": lambda: (self.dist / "appcast-x86_64.xml").unlink(),
            "extra": lambda: (self.dist / "RawLab.Desktop-stable-Portable.zip").write_bytes(b"portable"),
            "sum-mismatch": lambda: (self.dist / "BUILD-PROVENANCE.json").write_bytes(b"tampered"),
        }
        messages = {"missing": "missing asset: appcast-x86_64.xml",
                    "extra": "unexpected file in dist: RawLab.Desktop-stable-Portable.zip",
                    "sum-mismatch": "SHA256SUMS.txt mismatch: BUILD-PROVENANCE.json"}
        for name, mutate in cases.items():
            with self.subTest(case=name):
                self.setUp()
                mutate()
                result = self.run_script()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(messages[name], result.stderr)
                self.assertEqual(self.calls(), [], "no gh call may happen before the local check passes")

    def test_published_release_is_refused_and_existing_draft_is_verified_only(self):
        (self.state / "release.json").write_text(json.dumps({"draft": False, "tag": "v9.8.7"}))
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("already published", result.stderr)
        self.assertFalse([c for c in self.calls() if c[:2] in (["release", "create"], ["release", "upload"])])

        (self.state / "release.json").write_text(json.dumps({"draft": True, "tag": "v9.8.7"}))
        self.assertEqual(self.run_script().returncode, 0)
        before = len([c for c in self.calls() if c[:2] == ["release", "upload"]])
        verify = self.run_script("--verify-only")
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        self.assertEqual(len([c for c in self.calls() if c[:2] == ["release", "upload"]]), before)
        self.assertIn("remote: 13/13", verify.stdout)

    def test_missing_token_is_rejected_up_front(self):
        result = self.run_script(GH_TOKEN="")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("GH_TOKEN is not set", result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
