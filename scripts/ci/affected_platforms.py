"""Choose the platform checks a CI event runs, then require every chosen check to pass."""
import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request


PLATFORMS = ("macos", "windows", "android", "ios")
# No build, package or test reads these files. Anything not classified below selects every platform.
DOC_PREFIXES = ("docs/", "reviews/", ".impeccable/")
DOC_FILES = {"README.md", "CHANGELOG.md", "DESIGN.md", "PRODUCT.md", ".gitignore"}
DOC_NAMES = {"AGENTS.md", "CLAUDE.md"}
# Every client packages this notice even though it lives under docs/.
PACKAGED_DOCS = {"docs/reference/licensing.md"}
# Mac artwork, recipes and licenses are packaged by every client; iOS compiles one Mac test fixture.
SHARED_MAC_PREFIXES = ("RawLabMac/Resources/",)
MAC_AND_IOS_FILES = {"RawLabMac/tests/DCPTestFixtures.swift"}
CLIENT_DIRECTORIES = {"RawLab/": "ios", "RawLabMac/": "macos",
                      "RawLabWindows/": "windows", "RawLabAndroid/": "android"}


def platforms_for(path):
    if path in PACKAGED_DOCS:
        return set(PLATFORMS)
    if path.rsplit("/", 1)[-1] in DOC_NAMES or path in DOC_FILES or path.startswith(DOC_PREFIXES):
        return set()
    if path.startswith(SHARED_MAC_PREFIXES):
        return set(PLATFORMS)
    if path in MAC_AND_IOS_FILES:
        return {"macos", "ios"}
    for prefix, platform in CLIENT_DIRECTORIES.items():
        if path.startswith(prefix):
            return {platform}
    return set(PLATFORMS)


def affected(paths):
    selected = set()
    for path in paths:
        selected |= platforms_for(path)
    return selected


def is_cold_pull_request(pull):
    base, head = pull["base"]["ref"], pull["head"]["ref"]
    return base == "main" or base.startswith("release/") or head.startswith(("release/", "hotfix/"))


def select(event_name, event, sha, changed_files, last_success):
    """Return (platforms, cold, draft, reason).

    A push compares against the last successful push run rather than the previous commit:
    cancelled runs never verified their changes, and an unchanged platform is covered by the
    run that last verified its files. Any lookup failure selects every platform.
    """
    every = set(PLATFORMS)
    if event_name == "pull_request":
        pull = event["pull_request"]
        if pull.get("draft"):
            return set(), False, True, "draft pull request: platform checks wait for ready for review"
        if is_cold_pull_request(pull):
            return every, True, False, "release or hotfix pull request: full cold build"
        return _from_diff(lambda: changed_files("HEAD^1"), False, "pull request changes")
    if event_name == "push":
        def diff_since_last_success():
            base = last_success("push")
            if not base:
                raise LookupError("no earlier successful push run")
            return changed_files(base)
        return _from_diff(diff_since_last_success, False, "changes since the last successful push run")
    if event_name == "schedule":
        try:
            if last_success("schedule") == sha:
                return set(), True, False, "nightly: this commit already passed a cold build"
        except (OSError, ValueError, KeyError) as error:
            print(f"Cannot read the last nightly run ({error}); running the cold build", file=sys.stderr)
        return every, True, False, "nightly cold build"
    return every, True, False, f"{event_name}: full cold build"


def _from_diff(diff, cold, reason):
    try:
        paths = diff()
    except (OSError, ValueError, LookupError, KeyError, subprocess.CalledProcessError) as error:
        return set(PLATFORMS), cold, False, f"{reason} unavailable ({error}); running every platform"
    return affected(paths), cold, False, f"{reason}: {len(paths)} files"


def git_changed_files(base):
    if base != "HEAD^1":
        subprocess.run(["git", "fetch", "--no-tags", "--depth=1", "origin", base], check=True)
    output = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", base, "HEAD"], text=True)
    return [line for line in output.splitlines() if line]


def github_last_success(event):
    workflow = os.environ["GITHUB_WORKFLOW_REF"].split("@", 1)[0].rsplit("/", 1)[-1]
    query = urllib.parse.urlencode({"branch": os.environ["GITHUB_REF_NAME"], "event": event,
                                    "status": "success", "per_page": 1})
    url = (f"{os.environ.get('GITHUB_API_URL', 'https://api.github.com')}/repos/"
           f"{os.environ['GITHUB_REPOSITORY']}/actions/workflows/{workflow}/runs?{query}")
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        runs = json.load(response)["workflow_runs"]
    return runs[0]["head_sha"] if runs else None


def verify(needs):
    """List every way the run differs from 'selected checks passed, unselected checks skipped'."""
    errors = [f"{job} finished as {needs.get(job, {}).get('result')}"
              for job in ("changes", "contracts") if needs.get(job, {}).get("result") != "success"]
    outputs = needs.get("changes", {}).get("outputs", {})
    for platform in PLATFORMS:
        expected = "success" if outputs.get(platform) == "true" else "skipped"
        result = needs.get(platform, {}).get("result")
        if result != expected:
            errors.append(f"{platform} finished as {result}, expected {expected}")
    return errors


def windows_runner(event_name, cold):
    """Keep ordinary PRs out of the dedicated integration/release runner's queue."""
    if event_name == "pull_request" and not cold:
        return "windows-2022"
    return ["self-hosted", "windows", "x64", "rawlab-windows"]


def write_selection(platforms, cold, draft, reason, event_name):
    flags = {**{platform: platform in platforms for platform in PLATFORMS}, "cold": cold, "draft": draft}
    lines = [f"{name}={'true' if value else 'false'}" for name, value in flags.items()]
    lines.append("windows_runner=" + json.dumps(windows_runner(event_name, cold)))
    print(reason)
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("\n".join(lines) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        chosen = ", ".join(platform for platform in PLATFORMS if platform in platforms) or "none"
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"Platforms: **{chosen}**; cold dependency build: **{cold}**\n\n{reason}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("select", "verify", "classify"))
    parser.add_argument("paths", nargs="*", help="classify: repository-relative paths (default: stdin)")
    args = parser.parse_args()
    if args.mode == "classify":
        paths = args.paths or [line.strip() for line in sys.stdin if line.strip()]
        for path in paths:
            print(f"{','.join(sorted(platforms_for(path))) or '-'}\t{path}")
        print(f"selected: {','.join(p for p in PLATFORMS if p in affected(paths)) or 'none'}")
        return 0
    if args.mode == "verify":
        errors = verify(json.loads(os.environ["NEEDS"]))
        for error in errors:
            print(f"::error::{error}")
        return 1 if errors else 0
    event_name = os.environ["GITHUB_EVENT_NAME"]
    with open(os.environ["GITHUB_EVENT_PATH"]) as stream:
        event = json.load(stream)
    write_selection(*select(event_name, event, os.environ["GITHUB_SHA"],
                            git_changed_files, github_last_success), event_name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
