"""Choose the platform checks a CI event runs, then require every chosen check to pass."""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


PLATFORMS = ("macos", "windows", "android", "ios")
CHECK_GROUPS = ("contracts", "models", "build", "native", "full")
# Pure docs, bookkeeping, experiments, and standalone tools covered by `contracts` only.
# Unclassified root/misc paths also default to `set()` (`contracts` only) rather than all 4 platforms.
DOC_PREFIXES = (
    "docs/",
    ".impeccable/",
    "experiments/",
    "tools/camera-transfer/",
    # `contracts` runs `tools/mcp/tests` on every PR (skipping `test_real_cli.py` when
    # `RAWLAB_MCP_CLI` is unset); `macos` `native`/`full` and release/hotfix PRs (which
    # run every platform via `is_cold_pull_request()`) cover `mcp-cli-parity`.
    "tools/mcp/",
    ".github/ISSUE_TEMPLATE/",
)
DOC_FILES = {
    "README.md",
    "CHANGELOG.md",
    "DESIGN.md",
    "PRODUCT.md",
    ".gitignore",
    ".dsh-kanban.json",
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/CODEOWNERS",
    # Governs Python test discovery in `contracts` only; platform jobs do not consume it.
    "pyproject.toml",
}
DOC_NAMES = {"AGENTS.md", "CLAUDE.md"}
# Clients package these notices/schemas even though they live under doc-like paths.
PACKAGED_DOCS = {"docs/reference/licensing.md", "lutools/third_party/nikon_he/README.md"}
IOS_PACKAGED_DOCS = {"lutools/platform/ios/ThirdPartyNotices.md"}
# Mac artwork, recipes and licenses are packaged by every client; iOS compiles one Mac test fixture
# and sources the shared AX gate (RawLab/tests/ios-reset-entry-ui.sh) from a Mac path.
SHARED_MAC_PREFIXES = ("RawLabMac/Resources/",)
MAC_AND_IOS_FILES = {"RawLabMac/tests/DCPTestFixtures.swift", "RawLabMac/tests/ax-gate.sh", "Package.swift"}
APPLE_SHARED_PREFIXES = ("tests/RawLabKitTests/",)
CLIENT_DIRECTORIES = {"RawLab/": "ios", "RawLabMac/": "macos",
                      "RawLabWindows/": "windows", "RawLabAndroid/": "android"}
CLIENT_FILES = {"global.json": "windows"}
SHARED_PREFIXES = ("lutools/", "Shared/", "scripts/", "tests/", ".github/workflows/")
SHARED_FILES = {".gitattributes", "LICENSE", "LICENSE-ALIYUN-RUM-EXCEPTION", ".github/actionlint.yaml"}
# Inputs of the core CTest row outside lutools/: looks and externalized assets the tests read,
# CTest drivers and their Python requirements, the row's Rust and dependency-cache helpers, and
# the scripts RawLabMac/build.sh runs up to the core build (RAWLAB_CORE_ONLY skips the Sparkle and
# usage-SDK preparation). lutools/platform/ios/ is iOS framework glue; the iOS job covers it.
CORE_INPUT_FILES = {
    "Shared/assets-manifest.json", "scripts/assets/prepare.py", "scripts/ci/test_abi_layout.py",
    # hdr_display_mapping checks these Metal parity goldens bit-exact against the core.
    "Shared/fixtures/hdr-display-goldens-v1.json",
    "scripts/ci/check_ctest_inventory.py", "scripts/ci/requirements.txt", "scripts/ci/apple-sdk-env.sh",
    "scripts/ci/prepare-rust.sh", "scripts/ci/native_cache.py",
    "RawLabMac/build.sh", "RawLabMac/build-env.sh", "RawLabMac/release-config.sh",
    "RawLabMac/build-dependencies.sh", "RawLabMac/build-chroma-dependency.sh",
    "RawLabMac/build-wavelet-dependency.sh", "RawLabMac/build-tiff-dependency.sh",
    "RawLabMac/build-lens-dependency.sh",
}
CORE_INPUT_PREFIXES = ("Shared/BundledLooks/",)
CORE_EXCLUDED_PREFIXES = ("lutools/platform/ios/",)
# Job names in ci.yml. A description-edit run names its selection job EDIT_JOB, so a later
# edit run can tell automatic runs (which select checks) from earlier edit runs.
SELECT_JOB = "Select affected platforms"
EDIT_JOB = "Reuse the CI result of this head"
RESULT_JOB = "CI result"


def _is_lutools_doc(path):
    if path in {"lutools/README.md", "lutools/PROJECT_SUMMARY.md"}:
        return True
    # Preserve `lutools/docs/edit-json-v*.schema.json` (packaged by Windows & validated by tests).
    if path.startswith("lutools/docs/") and path.endswith(".md"):
        return True
    if path.startswith("lutools/platform/") and path.endswith("/README.md") and path.count("/") == 3:
        return True
    if path.startswith(("lutools/tools/", "lutools/tests/")) and path.endswith("/README.md"):
        return True
    # Preserve `lutools/x3f-bridge/licenses/` (packaged by `lutools/x3f-bridge/collect_licenses.py`).
    if (path.startswith("lutools/x3f-bridge/")
            and not path.startswith("lutools/x3f-bridge/licenses/")
            and path.endswith(".md")):
        return True
    return False


def platforms_for(path):
    if path in PACKAGED_DOCS:
        return set(PLATFORMS)
    if path in IOS_PACKAGED_DOCS:
        return {"ios"}
    if (path.rsplit("/", 1)[-1] in DOC_NAMES
            or path in DOC_FILES
            or path.startswith(DOC_PREFIXES)
            or _is_lutools_doc(path)):
        return set()
    if path.startswith(SHARED_MAC_PREFIXES):
        return set(PLATFORMS)
    if path in MAC_AND_IOS_FILES or path.startswith(APPLE_SHARED_PREFIXES):
        return {"macos", "ios"}
    if path in CLIENT_FILES:
        return {CLIENT_FILES[path]}
    for prefix, platform in CLIENT_DIRECTORIES.items():
        if path.startswith(prefix):
            return {platform}
    if path in SHARED_FILES or path.startswith(SHARED_PREFIXES):
        return set(PLATFORMS)
    return set()


def is_core_path(path):
    """Whether a changed path can change the result of the macOS core CTest build."""
    if path.startswith("lutools/"):
        return not (path.startswith(CORE_EXCLUDED_PREFIXES) or _is_lutools_doc(path)
                    or path.rsplit("/", 1)[-1] in DOC_NAMES)
    return path in CORE_INPUT_FILES or path.startswith(CORE_INPUT_PREFIXES)


def wants_core_ctest(config, platforms, draft, paths):
    """Automatic models runs add the arm64 core CTest row when core inputs changed.

    `paths` is None when the diff was unavailable; that runs it rather than guessing. Release and
    hotfix full gates and manual groups keep their own native coverage.
    """
    if config["mode"] != "automatic" or config["checks"] != "models" or draft or "macos" not in platforms:
        return False
    return paths is None or any(is_core_path(path) for path in paths)


def affected(paths):
    selected = set()
    for path in paths:
        selected |= platforms_for(path)
    return selected


def is_external_pull_request(pull):
    head_repo = (pull.get("head") or {}).get("repo") or {}
    base_repo = (pull.get("base") or {}).get("repo") or {}
    return bool(head_repo.get("full_name") and base_repo.get("full_name")
                and head_repo["full_name"] != base_repo["full_name"])


def is_cold_pull_request(pull):
    # 外部贡献者的分支名不可信：一个 fork 里的 hotfix/* 不该触发全量冷构建。
    if is_external_pull_request(pull):
        return False
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


def macos_matrix(checks, core_ctest=False):
    arm = {"runner": "macos-26", "arch": "arm64", "jobs": "2", "suite": "all"}
    intel = {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4"}
    if core_ctest and checks != "models":
        raise ValueError("The core CTest row belongs to automatic models runs")
    if checks in ("contracts", "models"):
        # The ctest row reuses the arm64 dependency cache (its key ignores the suite).
        return [arm, {**arm, "suite": "ctest"}] if core_ctest else [arm]
    if checks == "build":
        return [arm, {**intel, "suite": "build"}]
    # full is a cold build: every shard would rebuild every dependency, lutools and the app
    # (~40 min each), so one Intel job builds once and runs core, agent and render in turn.
    # native restores the dependency cache, so its parallel shards stay cheaper in wall time.
    if checks == "full":
        return [arm, {**intel, "suite": "intel"}]
    return [arm, *[{**intel, "suite": suite} for suite in ("core", "agent", "render")]]


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


def _github_get(path):
    url = f"{os.environ.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{os.environ['GITHUB_REPOSITORY']}/{path}"
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def _workflow_file():
    return os.environ["GITHUB_WORKFLOW_REF"].split("@", 1)[0].rsplit("/", 1)[-1]


def github_last_success(event):
    query = urllib.parse.urlencode({"branch": os.environ["GITHUB_REF_NAME"], "event": event,
                                    "status": "success", "per_page": 1})
    runs = _github_get(f"actions/workflows/{_workflow_file()}/runs?{query}")["workflow_runs"]
    return runs[0]["head_sha"] if runs else None


def is_description_edit(event_name, event):
    return event_name == "pull_request" and event.get("action") == "edited" and not (event.get("changes") or {}).get("base")


def edit_reference(runs, jobs_of, own_id):
    """Return the CI result conclusion of the newest automatic run created before this edit run.

    GitHub evaluates the newest pull_request run of the workflow on the head, so a title/body
    edit run must report the head's existing verdict itself. None means that run has not
    reported yet; a missing, skipped or cancelled result is not a pass. Earlier edit runs are
    passed over, and so is a run cancelled before its selection job was named (normally an edit
    run superseded by the next edit). Any other completed run without a selection job, such as
    one awaiting fork approval (action_required) or a startup_failure, fails closed instead of
    falling back to an older run that may have tested another base.
    """
    for run in sorted((run for run in runs if run["id"] < own_id), key=lambda run: run["id"], reverse=True):
        jobs = {job["name"]: job for job in jobs_of(run)}
        if EDIT_JOB in jobs:
            continue
        selection = jobs.get(SELECT_JOB)
        if selection is None:
            if run["status"] != "completed":
                return None
            if run.get("conclusion") == "cancelled":
                continue
            # Never pass through the run's own conclusion: without a CI result job it proves nothing.
            return f"not started ({run.get('conclusion')})"
        if selection["conclusion"] == "skipped":
            continue
        result = jobs.get(RESULT_JOB)
        if result and result["status"] == "completed":
            return result["conclusion"]
        return "missing" if run["status"] == "completed" else None
    return "missing"


def github_edit_reference(pull, own_id, workflow, get=None, clock=time.monotonic, sleep=time.sleep,
                          poll_seconds=60, limit_minutes=170):
    """Wait for the head's automatic CI result; stays inside the selection job's timeout.

    Jobs of a completed run attempt are fetched once, so each round costs one runs request plus
    one per unfinished run, however many earlier edits the head has.
    """
    get = get or _github_get
    query = urllib.parse.urlencode({"head_sha": pull["head"]["sha"], "event": "pull_request", "per_page": 100})
    finished_jobs = {}

    def runs():
        found = get(f"actions/workflows/{workflow}/runs?{query}")["workflow_runs"]
        return [run for run in found
                if any(item["number"] == pull["number"] for item in run.get("pull_requests") or [])
                or (not run.get("pull_requests") and run.get("head_branch") == pull["head"]["ref"])]

    def jobs_of(run):
        key = (run["id"], run.get("run_attempt"))
        if key in finished_jobs:
            return finished_jobs[key]
        jobs = get(f"actions/runs/{run['id']}/jobs?per_page=100")["jobs"]
        if run["status"] == "completed":
            finished_jobs[key] = jobs
        return jobs

    deadline = clock() + limit_minutes * 60
    while True:
        try:
            conclusion = edit_reference(runs(), jobs_of, own_id)
        except (OSError, urllib.error.URLError, ValueError, KeyError) as error:
            print(f"::warning::Run lookup failed, retrying: {error}", flush=True)
            conclusion = None
        if conclusion is not None:
            return conclusion
        if clock() >= deadline:
            return "still pending"
        sleep(poll_seconds)


def verify(needs):
    """List every way the run differs from 'selected checks passed, unselected checks skipped'."""
    outputs = needs.get("changes", {}).get("outputs", {})
    mode = outputs.get("mode")
    if mode == "edit":
        return _verify_edit(needs, outputs)
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
    errors += _verify_core_ctest(needs, outputs, mode, checks)
    batch_selection = mode == "automatic" and checks == "models" and outputs.get("windows") == "true"
    expected = "success" if batch_selection else "skipped"
    result = needs.get("windows-batch-selection", {}).get("result")
    if result != expected:
        errors.append(f"windows-batch-selection finished as {result}, expected {expected}")
    return errors


def _verify_core_ctest(needs, outputs, mode, checks):
    """A core change is only verified by a successful arm64 core CTest row in the macOS job."""
    flag = outputs.get("core_ctest", "false")
    try:
        rows = json.loads(outputs.get("macos_matrix") or "[]")
    except ValueError:
        return ["Unreadable macOS matrix"]
    ctest_rows = [row for row in rows if row.get("suite") == "ctest"]
    if flag == "false":
        return ["A core CTest row was scheduled without a core change"] if ctest_rows else []
    if flag != "true":
        return [f"Invalid core_ctest flag: {flag}"]
    errors = [] if mode == "automatic" and checks == "models" else ["Core CTest belongs to automatic models runs"]
    if ctest_rows != macos_matrix("models", core_ctest=True)[1:]:
        errors.append("Core code changed but the macOS matrix has no core CTest row")
    result = needs.get("macos", {}).get("result")
    if outputs.get("macos") != "true" or result != "success":
        errors.append(f"Core code changed but the macOS core CTest job finished as {result}, expected success")
    return errors


def _verify_edit(needs, outputs):
    reference = outputs.get("reference") or "missing"
    errors = [] if reference == "success" else [f"The automatic CI result for this head is {reference}, not success"]
    if outputs.get("contracts") != "false" or any(outputs.get(platform) != "false" for platform in PLATFORMS):
        errors.append("A description edit must not select checks")
    expected = {"changes": "success", "contracts": "skipped", "windows-batch-selection": "skipped",
                **{platform: "skipped" for platform in PLATFORMS}}
    errors += [f"{job} finished as {needs.get(job, {}).get('result')}, expected {result}"
               for job, result in expected.items() if needs.get(job, {}).get("result") != result]
    return errors


def windows_runner(event_name, cold, checks="full"):
    """Run every Windows group on an isolated GitHub-hosted runner."""
    return "windows-2022"


def write_selection(platforms, cold, draft, reason, event_name, config, extra=(), core_ctest=False):
    checks = config["checks"]
    flags = {**{platform: platform in platforms for platform in PLATFORMS}, "cold": cold, "draft": draft,
             "contracts": config["contracts"], "models": checks in ("models", "full"),
             "build": checks in ("build", "native", "full"), "native": checks in ("native", "full"),
             "core_ctest": core_ctest}
    lines = [f"{name}={'true' if value else 'false'}" for name, value in flags.items()]
    lines.append("windows_runner=" + json.dumps(windows_runner(event_name, cold, checks)))
    lines += ["mode=" + config["mode"], "scope=" + config["platform"], "checks=" + checks,
              "macos_matrix=" + json.dumps(macos_matrix(checks, core_ctest))]
    lines += [f"{name}={value}" for name, value in extra]
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
    if is_description_edit(event_name, event):
        pull = event["pull_request"]
        reference = "draft" if pull.get("draft") else github_edit_reference(
            pull, int(os.environ["GITHUB_RUN_ID"]), _workflow_file())
        config = {"mode": "edit", "platform": "none", "checks": "models", "contracts": False}
        write_selection(set(), False, bool(pull.get("draft")),
                        f"title/body edit: CI result reuses this head's automatic result ({reference})",
                        event_name, config, [("reference", reference)])
        return 0
    diffs = []
    def changed_files(base):
        diffs.append(git_changed_files(base))
        return diffs[-1]
    platforms, cold, draft, reason = select(event_name, event, os.environ["GITHUB_SHA"],
                                            changed_files, github_last_success)
    config = configuration(event_name, event)
    core_ctest = wants_core_ctest(config, platforms, draft, diffs[-1] if diffs else None)
    if core_ctest:
        reason += "; core inputs changed: macOS arm64 core CTest row added"
    write_selection(platforms, cold, draft, reason, event_name, config, core_ctest=core_ctest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
