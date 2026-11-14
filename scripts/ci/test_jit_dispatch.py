"""Decision-table regressions for the JIT dispatcher; the injected HTTP layer keeps them offline.

FakeAPI mirrors the live 2022-11-28 shapes pinned by the 2026-11-14 probe (request requires
name/runner_group_id/labels; response is {"runner": ..., "encoded_jit_config": ...}), so a stub
drift away from the real contract turns the table red."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import unittest.mock
import urllib.error

spec = importlib.util.spec_from_file_location("jit_dispatch", Path(__file__).with_name("jit_dispatch.py"))
jit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jit)

OWN = "dancancer/RawLab"
LABEL = "rawlab-apple"
FOREIGN = "contributor/RawLab"
REGISTRATION = ["self-hosted", "macOS", "ARM64", LABEL]
NO_JOB = f"labels-mismatch (no open job asks for {LABEL})"


def run(run_id=101, event="push", repo=OWN, branch="development", created="2026-11-13T00:00:00Z"):
    """A workflow-run list entry reduced to the fields the dispatcher trusts: all server-side."""
    return {"id": run_id, "event": event, "head_branch": branch, "status": "queued",
            "head_repository": {"full_name": repo}, "created_at": created}


def jobs(labels=None, status="queued", count=1):
    return [{"id": 900 + index, "status": status, "labels": list(labels or REGISTRATION)}
            for index in range(count)]


class FakeAPI:
    """Stub with the live-pinned contract: jobs list, queue, and the generate-jitconfig shapes.

    The stub also rejects request keys outside the pinned schema, so a reappearing invented
    field (runner_label, ephemeral, ...) turns the table red without touching the network."""

    def __init__(self, jobs_by_run=None, config="cfg-1", runs=()):
        self.jobs_by_run = jobs_by_run or {}
        self.config = config
        self.runs = list(runs)
        self.generated = []
        self.deleted = []

    def queued_runs(self):
        return self.runs

    def jobs(self, run_id):
        return self.jobs_by_run.get(run_id, [])

    def generate_jitconfig(self, payload):
        self.generated.append(payload)
        assert {"name", "runner_group_id", "labels"} <= set(payload) <= {"name", "runner_group_id",
                                                                         "labels", "work_folder"}, \
            f"request keys drifted from the pinned schema: {sorted(payload)}"
        runner = {"id": 25, "name": payload.get("name", ""), "os": "macOS", "status": "offline",
                  "busy": False, "version": "2.338.2", "runner_group_id": payload.get("runner_group_id"),
                  "labels": [{"id": 0, "name": label} for label in payload.get("labels", [])]}
        return {"runner": runner, "encoded_jit_config": self.config} if self.config else {"runner": runner}

    def delete_runner(self, runner_id):
        self.deleted.append(runner_id)


class FakeProcess:
    pid = 4242

    def __init__(self, returncode=0, raise_on_wait=None):
        self.returncode = returncode
        self.raise_on_wait = raise_on_wait

    def wait(self, timeout=None):
        if self.raise_on_wait:
            raise self.raise_on_wait
        return self.returncode


class DecisionTableTests(unittest.TestCase):
    """Every row asserts the exact verdict and reason, so any judgment flip turns the table red."""

    def decide(self, case, case_jobs=(), allowlist=()):
        return jit.dispatch_decision(case, list(case_jobs), repo=OWN, runner_label=LABEL,
                                     allowlist=set(allowlist))

    def test_push_on_this_repository_is_claimed(self):
        self.assertEqual(self.decide(run(), jobs()), (True, "trusted push on this repository"))

    def test_same_repository_pull_request_waits_for_the_allowlist(self):
        self.assertEqual(self.decide(run(event="pull_request", branch="feature/x"), jobs()),
                         (False, "untrusted (event=pull_request, head=dancancer/RawLab)"))

    def test_fork_pull_request_is_not_claimed(self):
        self.assertEqual(self.decide(run(event="pull_request", repo=FOREIGN), jobs()),
                         (False, "untrusted (event=pull_request, head=contributor/RawLab)"))

    def test_in_progress_job_is_already_claimed_and_never_resent(self):
        # Re-dispatching it would spend a JIT registration that no queued job picks up.
        self.assertEqual(self.decide(run(), jobs(status="in_progress")), (False, NO_JOB))

    def test_environment_gated_waiting_job_is_not_claimed(self):
        self.assertEqual(self.decide(run(), jobs(status="waiting")), (False, NO_JOB))

    def test_completed_jobs_are_not_claimed(self):
        self.assertEqual(self.decide(run(), jobs(status="completed")), (False, NO_JOB))

    def test_labels_without_the_runner_label_are_not_claimed(self):
        self.assertEqual(self.decide(run(), jobs(labels=["self-hosted", "rawlab-windows"])), (False, NO_JOB))

    def test_job_asking_a_label_we_do_not_register_is_not_claimed(self):
        heavier = jobs(labels=REGISTRATION + ["rawlab-heavy"])
        self.assertEqual(self.decide(run(), heavier), (False, NO_JOB))

    def test_job_with_a_subset_of_our_registration_is_claimed(self):
        self.assertEqual(self.decide(run(), jobs(labels=["self-hosted", LABEL])),
                         (True, "trusted push on this repository"))

    def test_labels_mismatch_stays_refused_even_when_allowlisted(self):
        self.assertEqual(self.decide(run(event="pull_request", repo=FOREIGN),
                                     jobs(labels=["self-hosted", "rawlab-android"]), {"contributor/RawLab"}),
                         (False, NO_JOB))

    def test_unplanned_run_retries_instead_of_being_claimed(self):
        self.assertEqual(self.decide(run(), []), (False, "await-planning (jobs not visible yet)"))

    def test_push_from_another_repository_is_not_trusted(self):
        self.assertEqual(self.decide(run(repo=FOREIGN), jobs()),
                         (False, "untrusted (event=push, head=contributor/RawLab)"))

    def test_workflow_dispatch_needs_the_allowlist(self):
        self.assertEqual(self.decide(run(event="workflow_dispatch"), jobs()),
                         (False, "untrusted (event=workflow_dispatch, head=dancancer/RawLab)"))

    def test_untrusted_run_never_consults_jobs_for_trust_verdict(self):
        self.assertEqual(self.decide(run(event="pull_request", repo=FOREIGN), []),
                         (False, "untrusted (event=pull_request, head=contributor/RawLab)"))

    def test_allowlist_admits_a_fork_pull_request_by_run_repo_and_repo_branch(self):
        fork = run(run_id=777, event="pull_request", repo=FOREIGN, branch="feature/x")
        for entry in ("777", "contributor/RawLab", "Contributor/RawLab:feature/x"):
            with self.subTest(entry=entry):
                self.assertEqual(self.decide(fork, jobs(), jit.parse_allowlist(entry)),
                                 (True, f"allowlisted ({entry.lower()})"))

    def test_allowlist_entries_are_normalized_and_case_insensitive(self):
        self.assertEqual(jit.parse_allowlist(" A/b, 777 ,,C:d "), {"a/b", "777", "c:d"})


class QueuePassTests(unittest.TestCase):
    def test_empty_queue_claims_nothing(self):
        self.assertIsNone(jit.next_dispatch([], FakeAPI()))

    def test_fork_only_queue_is_never_claimed_and_never_generates_a_token(self):
        queue = [run(run_id=2, event="pull_request", repo=FOREIGN)]
        api = FakeAPI(jobs_by_run={2: jobs()})
        reasons = []
        self.assertIsNone(jit.next_dispatch(queue, api.jobs, log=lambda _run, d: reasons.append(d.reason)))
        self.assertEqual(reasons, ["untrusted (event=pull_request, head=contributor/RawLab)"])
        self.assertEqual(api.generated, [])

    def test_newer_untrusted_run_blocks_older_push_with_dag_delayed_job(self):
        # B1 bypass 1: push created_at precedes fork, but needs:changes delays push job queuing.
        push_run = {**run(run_id=43556316863, created="2026-11-14T04:22:19Z"),
                    "run_started_at": "2026-11-14T04:22:22Z"}
        fork_run = run(run_id=43556320001, event="pull_request", repo=FOREIGN, created="2026-11-14T04:22:21Z")
        fetched, logged = [], []

        def jobs_of(run_id):
            fetched.append(run_id)
            ts = "2026-11-14T04:22:35Z" if run_id == 43556316863 else "2026-11-14T04:22:22Z"
            return [{"id": run_id + 1000, "status": "queued", "labels": REGISTRATION, "created_at": ts}]

        self.assertIsNone(jit.next_dispatch([fork_run, push_run], jobs_of,
                                            log=lambda r, d: logged.append((r["id"], d.reason))))
        self.assertEqual(fetched, [])
        self.assertEqual(logged, [(43556320001, "untrusted (event=pull_request, head=contributor/RawLab)")])

    def test_untrusted_run_blocks_rerun_of_older_historical_push(self):
        # B1 bypass 2: re-running an older push preserves run.created_at while queuing new jobs behind fork.
        rerun_push = {**run(run_id=10, created="2026-11-14T03:00:00Z"),
                      "run_started_at": "2026-11-14T05:00:00Z"}
        fork_run = run(run_id=20, event="pull_request", repo=FOREIGN, created="2026-11-14T04:00:00Z")
        fetched = []

        def jobs_of(run_id):
            fetched.append(run_id)
            ts = "2026-11-14T05:00:15Z" if run_id == 10 else "2026-11-14T04:00:05Z"
            return [{"id": run_id + 900, "status": "queued", "labels": REGISTRATION, "created_at": ts}]

        self.assertIsNone(jit.next_dispatch([fork_run, rerun_push], jobs_of))
        self.assertEqual(fetched, [])

    def test_trusted_only_queue_dispatches_oldest_matching_run(self):
        android_push = run(run_id=1, created="2026-11-13T00:00:00Z")
        newer_push = run(run_id=2, created="2026-11-13T00:02:00Z")
        older_push = run(run_id=3, created="2026-11-13T00:01:00Z")
        api = FakeAPI(jobs_by_run={
            1: jobs(labels=["self-hosted", "rawlab-android"]),
            2: jobs(),
            3: jobs(),
        })
        candidate = jit.next_dispatch([android_push, newer_push, older_push], api.jobs)
        self.assertEqual(candidate["id"], 3)

    def test_untrusted_head_run_blocks_newer_trusted_runs(self):
        fork = run(run_id=1, event="pull_request", repo=FOREIGN, created="2026-11-13T00:00:00Z")
        push = run(run_id=2, created="2026-11-13T00:01:00Z")
        api = FakeAPI(jobs_by_run={1: jobs(), 2: jobs()})
        self.assertIsNone(jit.next_dispatch([fork, push], api.jobs))

    def test_untrusted_in_progress_run_blocks_newer_trusted_runs(self):
        fork = {**run(run_id=1, event="pull_request", repo=FOREIGN, created="2026-11-13T00:00:00Z"),
                "status": "in_progress"}
        push = run(run_id=2, created="2026-11-13T00:01:00Z")
        api = FakeAPI(jobs_by_run={1: jobs(), 2: jobs()})
        self.assertIsNone(jit.next_dispatch([fork, push], api.jobs))

    def test_trusted_mismatch_then_untrusted_barrier_blocks_later_push(self):
        android_push = run(run_id=1, created="2026-11-13T00:00:00Z")
        fork = run(run_id=2, event="pull_request", repo=FOREIGN, created="2026-11-13T00:01:00Z")
        apple_push = run(run_id=3, created="2026-11-13T00:02:00Z")
        fetched = []

        def jobs_of(run_id):
            fetched.append(run_id)
            return jobs(labels=["self-hosted", "rawlab-android"]) if run_id == 1 else jobs()

        self.assertIsNone(jit.next_dispatch([android_push, fork, apple_push], jobs_of))
        self.assertEqual(fetched, [], "must pre-scan all runs for trust before spending any /jobs quota")

    def test_untrusted_run_never_fetches_jobs(self):
        fork = run(run_id=1, event="pull_request", repo=FOREIGN, created="2026-11-13T00:00:00Z")
        push = run(run_id=2, created="2026-11-13T00:01:00Z")
        fetched = []

        def jobs_of(run_id):
            fetched.append(run_id)
            return jobs()

        self.assertIsNone(jit.next_dispatch([fork, push], jobs_of))
        self.assertEqual(fetched, [])

    def test_unplanned_runs_are_skipped_and_rechecked_next_pass(self):
        unplanned = run(run_id=4)
        push = run(run_id=5, created="2026-11-13T00:02:00Z")
        api = FakeAPI(jobs_by_run={5: jobs()})  # run 4 has no visible jobs yet
        candidate = jit.next_dispatch([unplanned, push], api.jobs)
        self.assertEqual(candidate["id"], 5)

    def test_allowlisted_fork_is_claimed_when_it_is_the_only_trusted_run(self):
        fork = run(run_id=6, event="pull_request", repo=FOREIGN)
        api = FakeAPI(jobs_by_run={6: jobs()})
        candidate = jit.next_dispatch([fork], api.jobs, allowlist={"contributor/RawLab"})
        self.assertEqual(candidate["id"], 6)

    def test_job_running_elsewhere_does_not_block_the_queued_sibling(self):
        # Two rawlab-apple machines: one job in_progress on the other, one still queued here.
        mixed = [{"id": 900, "status": "in_progress", "labels": REGISTRATION},
                 {"id": 901, "status": "queued", "labels": REGISTRATION}]
        api = FakeAPI(jobs_by_run={7: mixed})
        candidate = jit.next_dispatch([run(run_id=7)], api.jobs)
        self.assertEqual(candidate["id"], 7)


class DispatchPayloadTests(unittest.TestCase):
    def setUp(self):
        self.launches = []

    def launch(self, config, runner_dir, argv, timeout):
        self.launches.append((config, runner_dir, argv, timeout))
        return 0

    def popen_factory(self, seen, process=None):
        def factory(argv, cwd=None, env=None, start_new_session=False):
            seen.update(argv=argv, cwd=cwd, env=env, start_new_session=start_new_session)
            return process or FakeProcess()
        return factory

    def test_jit_payload_carries_the_live_pinned_contract(self):
        api = FakeAPI(jobs_by_run={101: jobs()})
        code = jit.dispatch(run(), api, runner_label=LABEL, work_folder="/Volumes/RawLabCI/_work",
                            launch_argv=None, run_process=self.launch, log=lambda *a: None)
        self.assertEqual(code, 0)
        payload = api.generated[0]
        self.assertEqual(set(payload), {"name", "runner_group_id", "labels", "work_folder"},
                         "the request schema is exactly these four keys; no invented fields")
        self.assertEqual(payload["runner_group_id"], 1, "the API 422s without the runner group (probe 2026-11-14)")
        self.assertEqual(payload["labels"], REGISTRATION)
        self.assertEqual(payload["work_folder"], "/Volumes/RawLabCI/_work")
        self.assertRegex(payload["name"], r"-101-900-[0-9a-f]{6}$")
        self.assertLessEqual(len(payload["name"]), 64, "unique suffix, clamped to the API's runner-name limit")
        self.assertEqual(self.launches, [("cfg-1", ".", None, jit.DEFAULT_RUNNER_TIMEOUT)])

    def test_missing_encoded_jit_config_deletes_the_registration(self):
        api = FakeAPI(jobs_by_run={101: jobs()}, config="")
        with self.assertRaisesRegex(RuntimeError, "encoded_jit_config"):
            jit.dispatch(run(), api, run_process=self.launch, log=lambda *a: None)
        self.assertEqual(self.launches, [])
        self.assertEqual(api.deleted, [25], "the POST created a runner; do not leak it offline")

    def test_nonzero_runner_exit_cleans_up_registration_and_returns_exit_code(self):
        api = FakeAPI(jobs_by_run={101: jobs()})
        code = jit.dispatch(run(), api, run_process=lambda *a: 17, log=lambda *a: None)
        self.assertEqual(code, 17)
        self.assertEqual(api.deleted, [25], "a failed ./run.sh exit must still delete the JIT registration")

    def test_cleanup_survives_http_exception_on_nonzero_exit(self):
        api = FakeAPI(jobs_by_run={101: jobs()})
        logged = []

        def fail_delete(runner_id):
            raise jit.http.client.HTTPException("boom")

        api.delete_runner = fail_delete
        code = jit.dispatch(run(), api, run_process=lambda *a: 17, log=logged.append)
        self.assertEqual(code, 17)
        self.assertTrue(any("could not delete leaked runner" in line for line in logged))

    def test_failed_launch_cleans_up_the_registration(self):
        api = FakeAPI(jobs_by_run={101: jobs()})

        def boom(config, runner_dir, argv, timeout):
            raise FileNotFoundError(2, "No such file or directory", "./run.sh")

        with self.assertRaises(FileNotFoundError):
            jit.dispatch(run(), api, run_process=boom, log=lambda *a: None)
        self.assertEqual(len(api.generated), 1)
        self.assertEqual(api.deleted, [25], "no offline-runner leak storm per poll interval")

    def test_vanished_job_aborts_before_spending_a_registration(self):
        api = FakeAPI(jobs_by_run={})  # another runner won the race between poll and dispatch
        self.assertIsNone(jit.dispatch(run(), api, run_process=self.launch, log=lambda *a: None))
        self.assertEqual(api.generated, [])
        self.assertEqual(self.launches, [])

    def test_precheck_refuses_before_spending_a_registration(self):
        api = FakeAPI(jobs_by_run={101: jobs()})
        with unittest.mock.patch.object(jit.subprocess, "Popen",
                                        lambda *a, **k: self.fail("must not reach Popen")):
            with self.assertRaisesRegex(RuntimeError, "no JIT registration spent"):
                jit.dispatch(run(), api, runner_dir="/definitely-missing-runner-dir", log=lambda *a: None)
        self.assertEqual(api.generated, [], "a bad --runner-dir must never burn JIT registrations")

    def test_precheck_passes_and_launch_reads_config_from_the_environment(self):
        with tempfile.TemporaryDirectory() as runner_dir:
            script = Path(runner_dir) / "run.sh"  # the script a fresh archive root actually ships
            script.write_text("#!/bin/sh\nexit 0\n")
            script.chmod(0o755)
            api = FakeAPI(jobs_by_run={101: jobs()})
            seen = {}
            with unittest.mock.patch.dict(os.environ, {"RAWLAB_JIT_TOKEN": "admin-pat"}), \
                    unittest.mock.patch.object(jit.subprocess, "Popen", self.popen_factory(seen)):
                code = jit.dispatch(run(), api, runner_dir=runner_dir, log=lambda *a: None)
        self.assertEqual(code, 0)
        self.assertEqual(seen["argv"], ["./run.sh"], "no token in argv for a three-hour job")
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-1")
        self.assertNotIn("RAWLAB_JIT_TOKEN", seen["env"])
        self.assertTrue(seen["start_new_session"], "timeout must SIGTERM the whole group, not orphan the listener")
        self.assertEqual(api.deleted, [])

    def test_launch_runner_defaults_to_run_sh_env_config_and_group_timeout(self):
        seen = {}
        with unittest.mock.patch.object(jit.subprocess, "Popen", self.popen_factory(seen)):
            self.assertEqual(jit.launch_runner("cfg-9", runner_dir="/jit-runner"), 0)
        self.assertEqual(seen["argv"], ["./run.sh"], "runsvc.sh at the root only exists after svc.sh install")
        self.assertEqual(seen["cwd"], "/jit-runner")
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")
        self.assertEqual(seen["env"]["GITHUB_ACTIONS_SERVICE_EXIT_AFTER_N_FAILURES"], "1")
        self.assertTrue(seen["start_new_session"])

    def test_launch_runner_strips_dispatcher_tokens_from_child_env(self):
        seen = {}
        with unittest.mock.patch.dict(os.environ, {
                "RAWLAB_JIT_TOKEN": "admin-pat", "GITHUB_TOKEN": "gh-pat", "KEEP_VAR": "ok"}), \
                unittest.mock.patch.object(jit.subprocess, "Popen", self.popen_factory(seen)):
            self.assertEqual(jit.launch_runner("cfg-9", runner_dir="/jit-runner"), 0)
        self.assertNotIn("RAWLAB_JIT_TOKEN", seen["env"])
        self.assertNotIn("GITHUB_TOKEN", seen["env"])
        self.assertEqual(seen["env"]["KEEP_VAR"], "ok")
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")

    def test_launch_timeout_sigterms_the_process_group(self):
        boom = subprocess.TimeoutExpired(cmd="./run.sh", timeout=1)
        killed = []
        with unittest.mock.patch.object(jit.subprocess, "Popen",
                                        lambda *a, **k: FakeProcess(raise_on_wait=boom)), \
                unittest.mock.patch.object(jit.os, "getpgid", lambda pid: 777), \
                unittest.mock.patch.object(jit.os, "killpg", lambda pgid, sig: killed.append((pgid, sig))):
            with self.assertRaises(subprocess.TimeoutExpired):
                jit.launch_runner("cfg-9")
        self.assertEqual(killed, [(777, jit.signal.SIGTERM)])

    def test_runsvc_override_reads_the_jit_config_from_the_environment(self):
        seen = {}
        with unittest.mock.patch.object(jit.subprocess, "Popen", self.popen_factory(seen)):
            jit.launch_runner("cfg-9", runner_dir="/jit-runner", argv="./bin/runsvc.sh")
        self.assertEqual(seen["argv"], ["./bin/runsvc.sh"], "service-mode variant lives under bin/ in a fresh archive")
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")

    def test_manual_run_sh_override_still_receives_the_config_via_placeholder(self):
        seen = {}
        with unittest.mock.patch.object(jit.subprocess, "Popen", self.popen_factory(seen)):
            jit.launch_runner("cfg-9", runner_dir="/jit-runner", argv="./run.sh --jitconfig {config}")
        self.assertEqual(seen["argv"], ["./run.sh", "--jitconfig", "cfg-9"])
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")


class ApiWiringTests(unittest.TestCase):
    def test_endpoints_and_payload_reach_the_injected_layer(self):
        calls = []

        def fake_request(method, path, payload):
            calls.append((method, path, payload))
            if "generate-jitconfig" in path:
                return {"runner": {"id": 25}, "encoded_jit_config": "cfg"}
            if "/jobs" in path:
                return {"jobs": []}
            return {"workflow_runs": [{"id": 5}]}

        api = jit.ActionsAPI("tok", repo=OWN, root="https://api.example", request=fake_request)
        self.assertEqual(api.queued_runs(), [{"id": 5}, {"id": 5}])
        self.assertEqual(api.jobs(5), [])
        self.assertEqual(api.generate_jitconfig({"name": "jit"}),
                         {"runner": {"id": 25}, "encoded_jit_config": "cfg"})
        api.delete_runner(25)
        self.assertEqual(calls[0], ("GET", "/repos/dancancer/RawLab/actions/runs?status=queued&per_page=100", None))
        self.assertEqual(calls[1], ("GET", "/repos/dancancer/RawLab/actions/runs?status=in_progress&per_page=100", None))
        self.assertEqual(calls[2], ("GET", "/repos/dancancer/RawLab/actions/runs/5/jobs?per_page=100", None))
        self.assertEqual(calls[3], ("POST", "/repos/dancancer/RawLab/actions/runners/generate-jitconfig", {"name": "jit"}))
        self.assertEqual(calls[4], ("DELETE", "/repos/dancancer/RawLab/actions/runners/25", None))

    def test_generate_jitconfig_permission_error_names_the_pat_scopes(self):
        def raise_403(method, path, payload):
            raise urllib.error.HTTPError("https://api.example", 403, "Forbidden", {}, io.BytesIO(b'{"message":"Forbidden"}'))

        api = jit.ActionsAPI("tok", request=raise_403)
        with self.assertRaisesRegex(RuntimeError, "Administration"):
            api.generate_jitconfig({"name": "jit"})

    def test_urllib_survives_the_empty_204_body_of_DELETE(self):
        class EmptyResponse:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            @staticmethod
            def read():
                return b""

        with unittest.mock.patch.object(jit.urllib.request, "urlopen", lambda request, timeout=None: EmptyResponse()):
            self.assertEqual(jit.ActionsAPI("tok").delete_runner(25), None)

    def test_queued_runs_and_jobs_paginate_full_pages(self):
        calls = []

        def fake_request(method, path, payload):
            calls.append((method, path))
            page = "page=2" in path
            if "/jobs" in path:
                items = [{"id": 200 + i} for i in range(2 if page else 100)]
                return {"jobs": items}
            items = [{"id": (200 if page else 0) + i} for i in range(3 if page else 100)]
            return {"workflow_runs": items}

        api = jit.ActionsAPI("tok", repo=OWN, root="https://api.example", request=fake_request)
        runs = api.queued_runs()
        run_jobs = api.jobs(5)
        self.assertEqual(len(runs), 206)
        self.assertEqual(len(run_jobs), 102)
        self.assertIn(("GET", "/repos/dancancer/RawLab/actions/runs?status=queued&per_page=100&page=2"), calls)
        self.assertIn(("GET", "/repos/dancancer/RawLab/actions/runs?status=in_progress&per_page=100&page=2"), calls)
        self.assertIn(("GET", "/repos/dancancer/RawLab/actions/runs/5/jobs?per_page=100&page=2"), calls)

        exact_api = jit.ActionsAPI(
            "tok", repo=OWN, root="https://api.example",
            request=lambda m, p, pl: {"workflow_runs": [] if "page=2" in p else [{"id": i} for i in range(100)]})
        self.assertEqual(len(exact_api.queued_runs(statuses=("queued",))), 100)

    def test_pagination_fails_closed_when_max_pages_exceeded(self):
        def endless(method, path, payload):
            if "/jobs" in path:
                return {"jobs": [{"id": i} for i in range(100)]}
            return {"workflow_runs": [{"id": i} for i in range(100)]}

        api = jit.ActionsAPI("tok", repo=OWN, root="https://api.example", request=endless)
        with self.assertRaisesRegex(RuntimeError, "pages"):
            api.queued_runs(statuses=("queued",))
        with self.assertRaisesRegex(RuntimeError, "pages"):
            api.jobs(5)


class MainTests(unittest.TestCase):
    """--once must actually dispatch (the ci.md attack-verification checklist depends on it)."""

    def once(self, argv):
        dispatched = []
        api = FakeAPI(runs=[run()], jobs_by_run={101: jobs()})
        with contextlib.redirect_stderr(io.StringIO()) as err, unittest.mock.patch.dict(
                os.environ, {"RAWLAB_JIT_TOKEN": "tok"}), \
                unittest.mock.patch.object(jit, "ActionsAPI", lambda token, repo=None: api), \
                unittest.mock.patch.object(jit, "dispatch", lambda candidate, _api, **kw: dispatched.append(candidate["id"]) or 0):
            code = jit.main(argv)
        return code, dispatched, err.getvalue()

    def test_once_dispatches_the_chosen_run(self):
        code, dispatched, _ = self.once(["--once"])
        self.assertEqual((code, dispatched), (0, [101]))

    def test_once_dry_run_decides_without_dispatching(self):
        code, dispatched, _ = self.once(["--once", "--dry-run"])
        self.assertEqual((code, dispatched), (0, []))

    def test_missing_token_names_the_fine_grained_permissions(self):
        with contextlib.redirect_stderr(io.StringIO()) as err, \
                unittest.mock.patch.dict(os.environ, {"RAWLAB_JIT_TOKEN": "", "GITHUB_TOKEN": ""}):
            code = jit.main(["--once"])
        self.assertEqual(code, 2)
        self.assertIn("Administration", err.getvalue())


class LaunchdExampleTests(unittest.TestCase):
    """B3: the plist must isolate JIT in a pristine runner directory, never the resident one."""

    @classmethod
    def setUpClass(cls):
        cls.text = (Path(__file__).with_name("launchd") / "com.rawlab.jit-dispatcher.plist").read_text()

    def test_plist_points_at_a_separate_jit_runner_directory(self):
        self.assertIn("<string>/Users/rawlab-ci/jit-runner</string>", self.text)
        self.assertNotIn("<string>/Users/rawlab-ci/runner</string>", self.text,
                         "sharing the resident directory would overwrite its .runner/.credentials")

    def test_plist_launches_the_script_a_fresh_archive_actually_ships(self):
        self.assertIn("<string>./run.sh</string>", self.text)
        self.assertNotIn("<string>./runsvc.sh</string>", self.text,
                         "runsvc.sh at the archive root only exists after svc.sh install")

    def test_plist_comments_carry_the_provisioned_environment_files(self):
        self.assertIn(".path", self.text, "the Apple jobs need the provisioned PATH file copied in")
        self.assertIn(".env", self.text, "DEVELOPER_DIR and the cache keys ride on the copied .env")

    def test_plist_declares_process_type_interactive(self):
        self.assertIn("<key>ProcessType</key>", self.text)


if __name__ == "__main__":
    unittest.main()
