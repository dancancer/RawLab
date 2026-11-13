"""Claim queued self-hosted jobs only after GitHub's server-side metadata passes a hard check.

The resident ``Runner.Listener`` lets whoever's workflow YAML reaches the machine decide what
executes, which is unsafe for a public repository with external fork PRs. This opt-in dispatcher
inverts that: the machine listens to nothing. The host polls the Actions queue, hard-checks the
server-side fields the workflow author cannot forge (run ``event``, ``head_repository``, job
``labels``), and only then asks ``generate-jitconfig`` for a single-use registration so one
ephemeral runner (``config.sh --ephemeral`` semantics via ``run.sh --jitconfig``) claims a job
and burns itself down. A fork or non-conforming run is never claimed unless the operator listed
it in the allowlist; it simply waits in the queue and expires.

State discipline: every decision lives in memory and in GitHub's own queue, so retiring the
dispatcher means deleting these files (see docs/process/ci.md); nothing private is left behind.
"""
import argparse
from collections import namedtuple
import json
import os
import shlex
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request


API_VERSION = "2022-11-28"
DEFAULT_REPO = "dancancer/RawLab"
DEFAULT_RUNNER_LABEL = "rawlab-apple"
# The labels an ephemeral runner registers with; they mirror the runs-on route in ci.yml.
DEFAULT_RUNNER_LABELS = "self-hosted,macOS,ARM64,rawlab-apple"
# The whole queue surface that could wait for this machine; finished runs need no runner.
POLL_STATUSES = ("queued", "in_progress")
# A job that can still receive a runner. `waiting` (unapproved fork jobs) counts as open so the
# label check sees it and the trust check refuses it, instead of the run silently vanishing.
OPEN_JOB_STATUSES = ("queued", "waiting", "pending", "requested", "in_progress")

Decision = namedtuple("Decision", ("dispatch", "reason"))


def parse_allowlist(value):
    """Parse the comma-separated operator allowlist into normalized entries."""
    return {entry.strip().lower() for entry in (value or "").split(",") if entry.strip()}


def allowlist_match(run, allowlist):
    """Return the allowlist entry naming this run, matched only on server-side fields.

    An entry is the run id, the head repository full name, or ``head-repo:head-branch``.
    The operator adds entries after reviewing a run; the workflow YAML has no say here."""
    head_repo = ((run.get("head_repository") or {}).get("full_name") or "").lower()
    candidates = {str(run.get("id", "")).lower()}
    if head_repo:
        candidates |= {head_repo, f"{head_repo}:{(run.get('head_branch') or '').lower()}"}
    matched = candidates & {entry.lower() for entry in allowlist}
    return sorted(matched)[0] if matched else ""


def open_runner_jobs(jobs, runner_label):
    """Open jobs whose labels route to this machine's runner label."""
    return [job for job in jobs
            if job.get("status") in OPEN_JOB_STATUSES
            and runner_label.lower() in [str(label).lower() for label in (job.get("labels") or [])]]


def dispatch_decision(run, jobs, *, repo=DEFAULT_REPO, runner_label=DEFAULT_RUNNER_LABEL,
                      allowlist=frozenset()):
    """Hard-check server metadata and decide whether this machine may claim the run.

    Trust comes only from GitHub: a push on this repository's own branches, or an explicit
    allowlist entry. Nothing read from the run's YAML (jobs, steps, if-conditions) is consulted,
    because a fork PR ships its own YAML."""
    if open_runner_jobs(jobs, runner_label):
        entry = allowlist_match(run, allowlist)
        if entry:
            return Decision(True, f"allowlisted ({entry})")
        head_repo = (run.get("head_repository") or {}).get("full_name") or ""
        event = run.get("event") or "none"
        if run.get("event") == "push" and head_repo.lower() == repo.lower():
            return Decision(True, "trusted push on this repository")
        return Decision(False, f"untrusted (event={event}, head={head_repo or 'none'})")
    if jobs:
        return Decision(False, f"labels-mismatch (no open job asks for {runner_label})")
    return Decision(False, "await-planning (jobs not visible yet)")


def next_dispatch(runs, jobs_of, *, repo=DEFAULT_REPO, runner_label=DEFAULT_RUNNER_LABEL,
                  allowlist=frozenset(), log=None):
    """Oldest-first queue pass; return the first run this machine may claim.

    Untrusted runs are skipped over, not treated as a head barrier: a queued job GitHub has
    already accepted may still be picked first by an ephemeral runner started for a trusted run
    (the JIT service assigns by label FIFO, not by run), and docs/process/ci.md records that
    caveat instead of pretending the API can pin a job."""
    for run in sorted(runs, key=lambda run: (run.get("created_at") or "", run.get("id") or 0)):
        decision = dispatch_decision(run, jobs_of(run["id"]), repo=repo,
                                     runner_label=runner_label, allowlist=allowlist)
        if log:
            log(run, decision)
        if decision.dispatch:
            return run
    return None


def launch_runner(config, runner_dir=".", argv=None):
    """Start the single-use runner. run.sh forwards --jitconfig; runsvc.sh reads the same
    configuration from ACTIONS_RUNNER_INPUT_JITCONFIG, so both launch styles work from one code path."""
    env = {**os.environ, "ACTIONS_RUNNER_INPUT_JITCONFIG": config}
    parts = [part.replace("{config}", config)
             for part in (shlex.split(argv) if argv else ["./run.sh", "--jitconfig", "{config}"])]
    return subprocess.run(parts, cwd=runner_dir, env=env).returncode


class ActionsAPI:
    """Thin GitHub Actions REST wrapper; tests inject `request` and never touch the network."""

    def __init__(self, token, repo=DEFAULT_REPO, root=None, request=None):
        self.token = token
        self.repo = repo
        self.root = root or os.environ.get("GITHUB_API_URL", "https://api.github.com")
        self._request = request or self._urllib

    def _urllib(self, method, path, payload):
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(self.root + path, data=data, method=method, headers={
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": API_VERSION,
            "Authorization": f"Bearer {self.token}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def queued_runs(self, statuses=POLL_STATUSES):
        """Every run that could wait for this machine (one page each; this repo never fills one)."""
        runs = []
        for status in statuses:
            query = urllib.parse.urlencode({"status": status, "per_page": 100})
            runs += self._request("GET", f"/repos/{self.repo}/actions/runs?{query}", None)["workflow_runs"]
        return runs

    def jobs(self, run_id):
        query = urllib.parse.urlencode({"per_page": 100})
        return self._request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?{query}", None)["jobs"]

    def generate_jitconfig(self, payload):
        return self._request("POST", f"/repos/{self.repo}/actions/runners/generate-jitconfig", payload)


def dispatch(run, api, *, runner_label=DEFAULT_RUNNER_LABEL,
             labels=None, work_dir="", runner_dir=".", launch_argv=None,
             run_process=None, log=print):
    """Ask for a single-use, label-bound registration and run exactly one job, then exit."""
    ours = open_runner_jobs(api.jobs(run["id"]), runner_label)
    job_id = ours[0].get("id") if ours else "unknown"
    name = f"jit-{socket.gethostname().split('.')[0]}-{run['id']}-{job_id}"
    registration = list(labels) if labels else DEFAULT_RUNNER_LABELS.split(",")
    payload = {"name": name, "labels": registration, "runner_label": runner_label, "ephemeral": True}
    if work_dir:
        payload["work_directory"] = work_dir
    response = api.generate_jitconfig(payload)
    config = response.get("jitConfig") or response.get("jitconfig") or ""
    if not config:
        raise RuntimeError(f"generate-jitconfig returned no jitConfig for run {run['id']}")
    log(f"run {run['id']}: launching ephemeral runner {name} for job {job_id}")
    process = run_process or launch_runner
    return process(config, runner_dir, launch_argv)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Poll the Actions queue and hand only trusted runs to ephemeral runners.")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPO))
    parser.add_argument("--runner-label", default=DEFAULT_RUNNER_LABEL,
                        help="label generate-jitconfig binds the single job to (default: %(default)s)")
    parser.add_argument("--runner-labels", default=DEFAULT_RUNNER_LABELS,
                        help="comma-separated labels the ephemeral runner registers with")
    parser.add_argument("--allow", action="append", default=[],
                        help="extra allowlist entry (run id, head repo, or head-repo:branch); repeatable")
    parser.add_argument("--allowlist-env", default="RAWLAB_JIT_ALLOWLIST",
                        help="environment variable holding the comma-separated allowlist")
    parser.add_argument("--runner-dir", default=".", help="actions/runner directory used to launch the runner")
    parser.add_argument("--work-dir", default="", help="runner work_directory passed to generate-jitconfig")
    parser.add_argument("--launch-command", default="",
                        help="runner launch override; the token {config} is replaced with the JIT config "
                             "(default: './run.sh --jitconfig {config}'; use './runsvc.sh' to launch via env)")
    parser.add_argument("--interval", type=int, default=30, help="seconds between queue passes")
    parser.add_argument("--once", action="store_true", help="print one queue pass without dispatching, then exit")
    parser.add_argument("--dry-run", action="store_true", help="keep polling and log decisions without dispatching")
    args = parser.parse_args(argv)
    token = os.environ.get("RAWLAB_JIT_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("Set RAWLAB_JIT_TOKEN (fine-grained PAT with Actions: write on the repository).", file=sys.stderr)
        return 2
    allowlist = parse_allowlist(os.environ.get(args.allowlist_env, "")) | {entry.lower() for entry in args.allow}
    labels = [label.strip() for label in args.runner_labels.split(",") if label.strip()]
    api = ActionsAPI(token, repo=args.repo)
    logged = set()

    def log(run, decision):
        # 每个 (run, reason) 只记一条，避免轮询日志刷屏；状态变化会自然再记新决定。
        key = (run.get("id"), decision.reason)
        if key not in logged:
            logged.add(key)
            print(f"run {run.get('id')} [{run.get('event')}] {run.get('head_branch')} "
                  f"head={(run.get('head_repository') or {}).get('full_name')}: "
                  f"{'claim' if decision.dispatch else 'skip'} ({decision.reason})", flush=True)

    while True:
        try:
            candidate = next_dispatch(api.queued_runs(), api.jobs, repo=args.repo,
                                      runner_label=args.runner_label, allowlist=allowlist, log=log)
            if candidate is not None and not (args.once or args.dry_run):
                code = dispatch(candidate, api, runner_label=args.runner_label,
                                labels=labels, work_dir=args.work_dir, runner_dir=args.runner_dir,
                                launch_argv=args.launch_command or None)
                print(f"runner for run {candidate['id']} exited with {code}", flush=True)
        except (OSError, ValueError, RuntimeError) as error:
            print(f"queue pass failed: {error}", file=sys.stderr, flush=True)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(max(args.interval, 5))


if __name__ == "__main__":
    sys.exit(main())
