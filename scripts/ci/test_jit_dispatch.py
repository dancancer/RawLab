"""Decision-table regressions for the JIT dispatcher; the injected HTTP layer keeps them offline."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("jit_dispatch", Path(__file__).with_name("jit_dispatch.py"))
jit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jit)

OWN = "dancancer/RawLab"
LABEL = "rawlab-apple"
FOREIGN = "contributor/RawLab"


def run(run_id=101, event="push", repo=OWN, branch="development", created="2026-11-13T00:00:00Z"):
    """A workflow-run list entry reduced to the fields the dispatcher trusts: all server-side."""
    return {"id": run_id, "event": event, "head_branch": branch, "status": "queued",
            "head_repository": {"full_name": repo}, "created_at": created}


def jobs(label=LABEL, status="queued", count=1):
    return [{"id": 900 + index, "status": status, "labels": ["self-hosted", "macOS", "ARM64", label]}
            for index in range(count)]


class FakeAPI:
    def __init__(self, jobs_by_run=None, config="cfg-1"):
        self.jobs_by_run = jobs_by_run or {}
        self.config = config
        self.generated = []

    def jobs(self, run_id):
        return self.jobs_by_run.get(run_id, [])

    def generate_jitconfig(self, payload):
        self.generated.append(payload)
        return {"jitConfig": self.config} if self.config else {"runner": {"id": 1}}


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

    def test_unapproved_waiting_fork_job_is_refused_by_trust_not_labels(self):
        self.assertEqual(self.decide(run(event="pull_request", repo=FOREIGN), jobs(status="waiting")),
                         (False, "untrusted (event=pull_request, head=contributor/RawLab)"))

    def test_labels_without_the_runner_label_are_not_claimed(self):
        foreign_labels = jobs(label="rawlab-windows")
        self.assertEqual(self.decide(run(), foreign_labels),
                         (False, "labels-mismatch (no open job asks for rawlab-apple)"))

    def test_labels_mismatch_stays_refused_even_when_allowlisted(self):
        self.assertEqual(self.decide(run(event="pull_request", repo=FOREIGN), jobs(label="rawlab-android"),
                                     {"contributor/RawLab"}),
                         (False, "labels-mismatch (no open job asks for rawlab-apple)"))

    def test_completed_jobs_are_not_claimed(self):
        self.assertEqual(self.decide(run(), jobs(status="completed")),
                         (False, "labels-mismatch (no open job asks for rawlab-apple)"))

    def test_unplanned_run_retries_instead_of_being_claimed(self):
        self.assertEqual(self.decide(run(), []), (False, "await-planning (jobs not visible yet)"))

    def test_push_from_another_repository_is_not_trusted(self):
        self.assertEqual(self.decide(run(repo=FOREIGN), jobs()),
                         (False, "untrusted (event=push, head=contributor/RawLab)"))

    def test_workflow_dispatch_needs_the_allowlist(self):
        self.assertEqual(self.decide(run(event="workflow_dispatch"), jobs()),
                         (False, "untrusted (event=workflow_dispatch, head=dancancer/RawLab)"))

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

    def test_oldest_trusted_run_wins_and_untrusted_runs_are_skipped_past(self):
        fork = run(run_id=1, event="pull_request", repo=FOREIGN, created="2026-11-13T00:00:00Z")
        push = run(run_id=2, created="2026-11-13T00:01:00Z")
        old_push = run(run_id=3, created="2026-11-12T23:59:00Z")
        api = FakeAPI(jobs_by_run={1: jobs(), 2: jobs(), 3: jobs()})
        candidate = jit.next_dispatch([fork, push, old_push], api.jobs)
        self.assertEqual(candidate["id"], 3)

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


class DispatchPayloadTests(unittest.TestCase):
    def launch(self, config, runner_dir, argv):
        self.launches.append((config, runner_dir, argv))
        return 0

    def setUp(self):
        self.launches = []

    def test_jit_payload_is_single_use_label_bound_and_names_the_job(self):
        api = FakeAPI(jobs_by_run={101: jobs()})
        code = jit.dispatch(run(), api, runner_label=LABEL, work_dir="/Volumes/RawLabCI/_work",
                            launch_argv=None, run_process=self.launch, log=lambda *a: None)
        self.assertEqual(code, 0)
        payload = api.generated[0]
        self.assertTrue(payload["ephemeral"], "the runner must burn down after one job")
        self.assertEqual(payload["runner_label"], LABEL)
        self.assertEqual(payload["labels"], ["self-hosted", "macOS", "ARM64", "rawlab-apple"])
        self.assertEqual(payload["work_directory"], "/Volumes/RawLabCI/_work")
        self.assertIn("-101-900", payload["name"])
        self.assertEqual(self.launches, [("cfg-1", ".", None)])

    def test_missing_jit_config_fails_instead_of_launching_anything(self):
        api = FakeAPI(jobs_by_run={101: jobs()}, config="")
        with self.assertRaises(RuntimeError):
            jit.dispatch(run(), api, run_process=self.launch, log=lambda *a: None)
        self.assertEqual(self.launches, [])

    def test_launch_runner_default_forwards_jitconfig_and_sets_the_service_env(self):
        seen = {}

        class Completed:
            returncode = 0

        def fake_run(argv, cwd, env):
            seen.update(argv=argv, cwd=cwd, env=env)
            return Completed()

        original = jit.subprocess.run
        jit.subprocess.run = fake_run
        try:
            self.assertEqual(jit.launch_runner("cfg-9", runner_dir="/runner"), 0)
        finally:
            jit.subprocess.run = original
        self.assertEqual(seen["argv"], ["./run.sh", "--jitconfig", "cfg-9"])
        self.assertEqual(seen["cwd"], "/runner")
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")

    def test_runsvc_launch_reads_the_jit_config_from_the_environment(self):
        seen = {}

        class Completed:
            returncode = 0

        def fake_run(argv, cwd, env):
            seen.update(argv=argv, env=env)
            return Completed()

        original = jit.subprocess.run
        jit.subprocess.run = fake_run
        try:
            jit.launch_runner("cfg-9", runner_dir="/runner", argv="./runsvc.sh")
        finally:
            jit.subprocess.run = original
        self.assertEqual(seen["argv"], ["./runsvc.sh"])
        self.assertEqual(seen["env"]["ACTIONS_RUNNER_INPUT_JITCONFIG"], "cfg-9")


class ApiWiringTests(unittest.TestCase):
    def test_endpoints_and_payload_reach_the_injected_layer(self):
        calls = []

        def fake_request(method, path, payload):
            calls.append((method, path, payload))
            if "generate-jitconfig" in path:
                return {"jitConfig": "cfg"}
            if "/jobs" in path:
                return {"jobs": []}
            return {"workflow_runs": [{"id": 5}]}

        api = jit.ActionsAPI("tok", repo=OWN, root="https://api.example", request=fake_request)
        self.assertEqual(api.queued_runs(), [{"id": 5}, {"id": 5}])
        self.assertEqual(api.jobs(5), [])
        self.assertEqual(api.generate_jitconfig({"name": "jit"}), {"jitConfig": "cfg"})
        self.assertEqual(calls[0], ("GET", "/repos/dancancer/RawLab/actions/runs?status=queued&per_page=100", None))
        self.assertEqual(calls[1], ("GET", "/repos/dancancer/RawLab/actions/runs?status=in_progress&per_page=100", None))
        self.assertEqual(calls[2], ("GET", "/repos/dancancer/RawLab/actions/runs/5/jobs?per_page=100", None))
        self.assertEqual(calls[3], ("POST", "/repos/dancancer/RawLab/actions/runners/generate-jitconfig", {"name": "jit"}))


if __name__ == "__main__":
    unittest.main()
