"""Claim queued self-hosted jobs only after GitHub's server-side metadata passes a hard check.

The resident ``Runner.Listener`` lets whoever's workflow YAML reaches the machine decide what
executes, which is unsafe for a public repository with external fork PRs. This opt-in dispatcher
inverts that: the machine listens to nothing. The host polls the Actions queue, hard-checks the
server-side fields the workflow author cannot forge (run ``event``, ``head_repository``, job
``labels``), and only then asks ``generate-jitconfig`` for a single-use registration whose
``encoded_jit_config`` starts one JIT runner (single job, self-deregistering) that claims a job
and burns itself down. A fork or non-conforming run is never claimed unless the operator listed
it in the allowlist; it simply waits in the queue and expires.

Live contract, pinned by a 2026-11-14 probe against REST API version 2022-11-28: the request
requires ``name``, ``runner_group_id`` (the Default group is ``1``) and ``labels`` (omitting the
group answers 422), the response is ``{"runner": {...}, "encoded_jit_config": "..."}``, and the
POST creates the runner registration immediately — a launch that never starts leaves an offline
runner to delete from Settings → runners. The fine-grained PAT therefore needs the repository
``Administration`` permission (write) plus ``Actions`` (read) for polling; a classic PAT needs
the ``repo`` scope.

State discipline: every decision lives in memory and in GitHub's own queue, so retiring the
dispatcher means deleting these files (see docs/process/ci.md); nothing private is left behind.
"""
import argparse
from collections import namedtuple
import http.client
import json
import os
import shlex
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


API_VERSION = "2022-11-28"
DEFAULT_REPO = "dancancer/RawLab"
DEFAULT_RUNNER_LABEL = "rawlab-apple"
# The labels an ephemeral runner registers with; they mirror the runs-on route in ci.yml.
DEFAULT_RUNNER_LABELS = "self-hosted,macOS,ARM64,rawlab-apple"
# The repository's Default runner group (probe 2026-11-14; required in the request body).
DEFAULT_RUNNER_GROUP_ID = 1
# The whole queue surface that could wait for this machine; finished runs need no runner.
POLL_STATUSES = ("queued", "in_progress")
# Jobs still waiting to be picked up. `in_progress` is excluded because such a job already has a
# runner (re-dispatching it would leak a registration); `waiting` is an environment gate, not a
# queued job; unapproved fork PRs never reach here at all — their runs hold status
# `action_required`, which the queue poll does not even fetch.
OPEN_JOB_STATUSES = ("queued", "pending", "requested")
# Hard backstop for one runner process; the workflow's own (180m) job timeout fires first.
DEFAULT_RUNNER_TIMEOUT = 6 * 3600

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


def open_runner_jobs(jobs, runner_label, runner_labels=DEFAULT_RUNNER_LABELS.split(",")):
    """Jobs queued for pickup that this machine could actually start: one of them asks for our
    runner label, and we register every label the job requests — a job wanting a label we do
    not carry would sit claimed-but-unserved, the same idle trap the resident listener has."""
    registered = {str(label).lower() for label in runner_labels}
    return [job for job in jobs
            if job.get("status") in OPEN_JOB_STATUSES
            and str(runner_label).lower() in {str(label).lower() for label in (job.get("labels") or [])}
            and {str(label).lower() for label in (job.get("labels") or [])} <= registered]


def dispatch_decision(run, jobs, *, repo=DEFAULT_REPO, runner_label=DEFAULT_RUNNER_LABEL,
                      runner_labels=DEFAULT_RUNNER_LABELS.split(","), allowlist=frozenset()):
    """Hard-check server metadata and decide whether this machine may claim the run.

    Trust comes only from GitHub: a push on this repository's own branches, or an explicit
    allowlist entry. Nothing read from the run's YAML (jobs, steps, if-conditions) is consulted,
    because a fork PR ships its own YAML."""
    if open_runner_jobs(jobs, runner_label, runner_labels):
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
                  runner_labels=DEFAULT_RUNNER_LABELS.split(","), allowlist=frozenset(), log=None):
    """Oldest-first queue pass; return the first run this machine may claim.

    Untrusted runs are skipped over, not treated as a head barrier: a queued job GitHub has
    already accepted may still be picked first by an ephemeral runner started for a trusted run
    (the JIT service assigns by label FIFO, not by run), and docs/process/ci.md records that
    caveat instead of pretending the API can pin a job."""
    for run in sorted(runs, key=lambda run: (run.get("created_at") or "", run.get("id") or 0)):
        decision = dispatch_decision(run, jobs_of(run["id"]), repo=repo, runner_label=runner_label,
                                     runner_labels=runner_labels, allowlist=allowlist)
        if log:
            log(run, decision)
        if decision.dispatch:
            return run
    return None


def launch_runner(config, runner_dir=".", argv=None, timeout=DEFAULT_RUNNER_TIMEOUT):
    """Start the single-use runner. The configuration travels only through
    ACTIONS_RUNNER_INPUT_JITCONFIG (never argv, so a long job does not expose it in `ps`) and
    GITHUB_ACTIONS_SERVICE_EXIT_AFTER_N_FAILURES=1 keeps RunnerService from retry-looping on a
    consumed config; the timeout is a last-resort backstop above the workflow's own timeout."""
    env = {**os.environ, "ACTIONS_RUNNER_INPUT_JITCONFIG": config,
           "GITHUB_ACTIONS_SERVICE_EXIT_AFTER_N_FAILURES": "1"}
    parts = [part.replace("{config}", config) for part in (shlex.split(argv) if argv else ["./runsvc.sh"])]
    return subprocess.run(parts, cwd=runner_dir, env=env, timeout=timeout).returncode


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
        try:
            return self._request("POST", f"/repos/{self.repo}/actions/runners/generate-jitconfig", payload)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 422):
                raise RuntimeError(
                    f"generate-jitconfig failed with HTTP {error.code}: {error.read().decode(errors='replace')[:200]} "
                    "(fine-grained PAT needs repository Administration: write plus Actions: read; classic: repo scope)") from error
            raise


def dispatch(run, api, *, runner_label=DEFAULT_RUNNER_LABEL, runner_labels=DEFAULT_RUNNER_LABELS.split(","),
             runner_group_id=DEFAULT_RUNNER_GROUP_ID, work_folder="", runner_dir=".", launch_argv=None,
             runner_timeout=DEFAULT_RUNNER_TIMEOUT, run_process=None, log=print):
    """Ask for a single-use registration and run exactly one job, then exit.

    The job list is re-read here; if another runner won the race in the meantime, the dispatch
    aborts before spending a JIT registration (the POST creates the runner record immediately)."""
    ours = open_runner_jobs(api.jobs(run["id"]), runner_label, runner_labels)
    if not ours:
        log(f"run {run['id']}: job vanished before dispatch; no JIT token spent")
        return None
    job_id = ours[0].get("id")
    name = f"jit-{socket.gethostname().split('.')[0]}-{run['id']}-{job_id}-{uuid.uuid4().hex[:6]}"[:64]
    payload = {"name": name, "runner_group_id": runner_group_id, "labels": list(runner_labels),
               "runner_label": runner_label, "ephemeral": True}
    if work_folder:
        payload["work_folder"] = work_folder
    response = api.generate_jitconfig(payload)
    config = response.get("encoded_jit_config") or ""
    if not config:
        raise RuntimeError(f"generate-jitconfig returned no encoded_jit_config for run {run['id']}; "
                           f"delete the runner registration '{name}' from Settings → runners")
    log(f"run {run['id']}: launching ephemeral runner {name} for job {job_id}")
    process = run_process or launch_runner
    return process(config, runner_dir, launch_argv, runner_timeout)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Poll the Actions queue and hand only trusted runs to ephemeral runners.")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPO))
    parser.add_argument("--runner-label", default=DEFAULT_RUNNER_LABEL,
                        help="label passed as runner_label to restrict the JIT job (default: %(default)s)")
    parser.add_argument("--runner-labels", default=DEFAULT_RUNNER_LABELS,
                        help="comma-separated labels the ephemeral runner registers with")
    parser.add_argument("--runner-group-id", type=int, default=DEFAULT_RUNNER_GROUP_ID,
                        help="repository runner group id (required by the API; default: %(default)s)")
    parser.add_argument("--allow", action="append", default=[],
                        help="extra allowlist entry (run id, head repo, or head-repo:branch); repeatable")
    parser.add_argument("--allowlist-env", default="RAWLAB_JIT_ALLOWLIST",
                        help="environment variable holding the comma-separated allowlist")
    parser.add_argument("--runner-dir", default=".",
                        help="pristine actions/runner directory for JIT only (keep the resident directory separate)")
    parser.add_argument("--work-folder", default="",
                        help="runner work_folder passed to generate-jitconfig (default: the server's _work)")
    parser.add_argument("--launch-command", default="",
                        help="runner launch override; the token {config} is replaced with the JIT config "
                             "(default: './runsvc.sh', which reads ACTIONS_RUNNER_INPUT_JITCONFIG)")
    parser.add_argument("--interval", type=int, default=30, help="seconds between queue passes")
    parser.add_argument("--runner-timeout", type=int, default=DEFAULT_RUNNER_TIMEOUT,
                        help="hard backstop seconds for one runner process, above the workflow timeout")
    parser.add_argument("--once", action="store_true",
                        help="single queue pass (dispatches at most one job unless --dry-run), then exit")
    parser.add_argument("--dry-run", action="store_true", help="decide without spending JIT registrations")
    args = parser.parse_args(argv)
    token = os.environ.get("RAWLAB_JIT_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("Set RAWLAB_JIT_TOKEN (fine-grained PAT: repository Administration write plus Actions "
              "read; classic PAT: repo scope).", file=sys.stderr)
        return 2
    allowlist = parse_allowlist(os.environ.get(args.allowlist_env, "")) | parse_allowlist(",".join(args.allow))
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
                                      runner_label=args.runner_label, runner_labels=labels,
                                      allowlist=allowlist, log=log)
            if candidate is not None and not args.dry_run:
                code = dispatch(candidate, api, runner_label=args.runner_label, runner_labels=labels,
                                runner_group_id=args.runner_group_id, work_folder=args.work_folder,
                                runner_dir=args.runner_dir, launch_argv=args.launch_command or None,
                                runner_timeout=args.runner_timeout)
                if code is not None:
                    print(f"runner for run {candidate['id']} exited with {code}", flush=True)
        except (OSError, ValueError, RuntimeError, KeyError, http.client.HTTPException,
                subprocess.SubprocessError) as error:
            print(f"queue pass failed: {error}", file=sys.stderr, flush=True)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(max(args.interval, 5))


if __name__ == "__main__":
    sys.exit(main())
