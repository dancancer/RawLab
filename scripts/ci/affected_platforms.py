"""Choose the platform checks a CI event runs, then require every chosen check to pass."""
import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request


PLATFORMS = ("macos", "windows", "android", "ios")
CHECK_GROUPS = ("contracts", "models", "build", "native", "full")
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


def configuration(event_name, event):
    if event_name == "workflow_dispatch":
        inputs = event.get("inputs", {})
        platform, checks = inputs.get("platform", "all"), inputs.get("checks", "models")
        if platform not in ("all", *PLATFORMS) or checks not in CHECK_GROUPS:
            raise ValueError(f"Unknown verification selection: {platform}/{checks}")
        return {"mode": "manual", "platform": platform, "checks": checks,
                "contracts": checks == "contracts" or (platform == "all" and checks == "full")}
    checks = "full" if event_name == "pull_request" and is_cold_pull_request(event["pull_request"]) else "models"
    return {"mode": "automatic", "platform": "affected", "checks": checks, "contracts": True}


def macos_matrix(checks):
    arm = {"runner": ["self-hosted", "macOS", "ARM64", "rawlab-apple"], "arch": "arm64", "jobs": "6", "suite": "all"}
    intel = {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4"}
    if checks in ("contracts", "models"):
        return [arm]
    return [arm, *[{**intel, "suite": suite} for suite in (("build",) if checks == "build" else ("core", "agent", "render"))]]


def select(event_name, event, sha, changed_files, last_success):
    """Return (platforms, cold, draft, reason).

    A push compares against the last successful push run rather than the previous commit:
    cancelled runs never verified their changes, and an unchanged platform is covered by the
    run that last verified its files. Any lookup failure selects every platform.
    """
    every = set(PLATFORMS)
    config = configuration(event_name, event)
    if event_name == "workflow_dispatch":
        platforms = set() if config["checks"] == "contracts" else every if config["platform"] == "all" else {config["platform"]}
        return platforms, config["checks"] == "full", False, f"manual {config['platform']}/{config['checks']}; separate from CI result"
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
    raise ValueError(f"Unsupported verification event: {event_name}")


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
    outputs = needs.get("changes", {}).get("outputs", {})
    mode = outputs.get("mode")
    checks = outputs.get("checks")
    scope = outputs.get("scope")
    errors = [] if mode in ("automatic", "manual") else [f"Unknown verification mode: {mode}"]
    if checks not in CHECK_GROUPS:
        errors.append(f"Unknown check group: {checks}")
    if mode == "automatic" and checks not in ("models", "full"):
        errors.append("Automatic events must use models or the full release gate")
    if outputs.get("cold") != ("true" if checks == "full" else "false"):
        errors.append(f"Invalid cold-build flag for {checks}")
    if (mode == "automatic" and scope != "affected") or (mode == "manual" and scope not in ("all", *PLATFORMS)):
        errors.append(f"Invalid verification scope: {scope}")
    for flag, enabled in (("models", checks in ("models", "full")),
                          ("build", checks in ("build", "native", "full")),
                          ("native", checks in ("native", "full"))):
        if outputs.get(flag) != ("true" if enabled else "false"):
            errors.append(f"Invalid {flag} flag for {checks}")
    contracts = mode == "automatic" or checks == "contracts" or (scope == "all" and checks == "full")
    if outputs.get("contracts") != ("true" if contracts else "false"):
        errors.append("Invalid contracts selection")
    expected_jobs = {"changes": "success", "contracts": "success" if outputs.get("contracts") == "true" else "skipped"}
    errors += [f"{job} finished as {needs.get(job, {}).get('result')}, expected {expected}"
               for job, expected in expected_jobs.items() if needs.get(job, {}).get("result") != expected]
    for platform in PLATFORMS:
        if outputs.get(platform) not in ("true", "false") or (checks == "contracts" and outputs.get(platform) != "false"):
            errors.append(f"Invalid {platform} selection")
        if mode == "manual" or (mode == "automatic" and checks == "full"):
            selected = checks != "contracts" and (scope in ("all", "affected") or scope == platform)
            if outputs.get(platform) != ("true" if selected else "false"):
                errors.append(f"{platform} differs from the requested {scope}/{checks} scope")
        expected = "success" if outputs.get(platform) == "true" else "skipped"
        result = needs.get(platform, {}).get("result")
        if result != expected:
            errors.append(f"{platform} finished as {result}, expected {expected}")
    return errors


def windows_runner(event_name, cold, checks="full"):
    """Keep ordinary PRs out of the dedicated integration/release runner's queue."""
    if checks == "models" or (event_name == "pull_request" and not cold):
        return "windows-2022"
    return ["self-hosted", "windows", "x64", "rawlab-windows"]


def write_selection(platforms, cold, draft, reason, event_name, config):
    checks = config["checks"]
    flags = {**{platform: platform in platforms for platform in PLATFORMS}, "cold": cold, "draft": draft,
             "contracts": config["contracts"], "models": checks in ("models", "full"),
             "build": checks in ("build", "native", "full"), "native": checks in ("native", "full")}
    lines = [f"{name}={'true' if value else 'false'}" for name, value in flags.items()]
    lines.append("windows_runner=" + json.dumps(windows_runner(event_name, cold, checks)))
    lines += ["mode=" + config["mode"], "scope=" + config["platform"], "checks=" + checks, "macos_matrix=" + json.dumps(macos_matrix(checks))]
    print(reason)
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("\n".join(lines) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        chosen = ", ".join(platform for platform in PLATFORMS if platform in platforms) or "none"
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"Platforms: **{chosen}**; checks: **{checks}**; cold dependency build: **{cold}**\n\n{reason}\n")


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
                            git_changed_files, github_last_success), event_name, configuration(event_name, event))
    return 0


if __name__ == "__main__":
    sys.exit(main())
