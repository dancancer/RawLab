"""Run apple-models suites concurrently and replay each suite's log once it finishes.

The bash runner used to reap children and replay logs itself. Its builtin `printf` into the
`tee` pipe failed on hosted macOS with "write error: Interrupted system call" and then kept
failing for every later suite, turning a green run red. Here every write retries EINTR
(PEP 475) and waits out a full non-blocking pipe, so scheduling and log replay live here while apple-models.sh keeps the CI invariant 7 SKIP rule: every finished
suite's log is judged by `apple-models.sh --check-skip LOG SUITE`, the single source of
that rule and of its AX honest-skip allow-list.

Exit status: 1 if any suite logged a forbidden SKIP, otherwise the exit code of the first
failing suite in completion order (128+N for a signal), otherwise 0. After the first
failure no further suites start; running suites finish and are replayed.
"""
import argparse
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


def suite_exit_code(returncode):
    return 128 - returncode if returncode < 0 else returncode


def write_fd(fd, data):
    # os.write retries EINTR itself (PEP 475). A stdout pipe shared with other processes can
    # also end up non-blocking; then wait until it is writable instead of failing the run.
    view = memoryview(data)
    while view:
        try:
            written = os.write(fd, view)
        except BlockingIOError:
            select.select([], [fd], [])
            continue
        view = view[written:]


def write_out(data):
    write_fd(sys.stdout.fileno(), data)


def report(message):
    write_fd(sys.stderr.fileno(), (message + "\n").encode())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--jobs", type=int, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--checker", required=True, help="apple-models.sh, called with --check-skip")
    parser.add_argument("suites", nargs="+")
    args = parser.parse_args(argv)
    jobs = max(1, args.jobs)
    logs = args.cache / "logs"
    work = args.cache / "work"
    logs.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    running = {}  # index -> Popen
    stopping = False

    def terminate(signum, _frame):
        for process in running.values():
            if process.poll() is None:
                process.terminate()
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)

    def launch(index):
        suite_tmp = work / str(index)
        suite_tmp.mkdir(parents=True, exist_ok=True)
        environment = dict(os.environ, TMPDIR=str(suite_tmp), RAWLAB_TEST_TMP_DIR=str(suite_tmp))
        with open(logs / f"{index}.log", "wb") as log:
            # `bash` is resolved from PATH, exactly like the former `exec bash "$suite"`.
            running[index] = subprocess.Popen(["bash", args.suites[index]], stdin=subprocess.DEVNULL,
                                              stdout=log, stderr=subprocess.STDOUT, env=environment)

    failures = []
    fail_rc = 0
    skip_fail = False
    next_index = 0
    while running or (not stopping and next_index < len(args.suites)):
        while not stopping and next_index < len(args.suites) and len(running) < jobs:
            launch(next_index)
            next_index += 1
        finished = [index for index, process in running.items() if process.poll() is not None]
        if not finished:
            time.sleep(0.05)
            continue
        for index in finished:
            rc = suite_exit_code(running.pop(index).returncode)
            suite = args.suites[index]
            log = logs / f"{index}.log"
            write_out(f"[model] {suite}\n".encode())
            write_out(log.read_bytes())
            # The checker prints the invariant 7 error itself; a non-zero status means a forbidden SKIP.
            if subprocess.run(["/bin/bash", args.checker, "--check-skip", str(log), suite]).returncode != 0:
                skip_fail = True
                failures.append(f"{suite} (logged SKIP)")
            if rc != 0:
                report(f"error: {suite} failed with exit code {rc}")
                failures.append(f"{suite} (exit {rc})")
                if fail_rc == 0:
                    fail_rc = rc
            if skip_fail or fail_rc:
                stopping = True

    if failures:
        report(f"error: apple models ({args.platform}): {len(failures)} failure(s)")
        not_started = len(args.suites) - next_index
        if not_started:
            report(f"error:   {not_started} queued suite(s) were not started after the first failure")
        for failure in failures:
            report(f"error:   {failure}")
    if skip_fail:
        return 1
    return fail_rc


if __name__ == "__main__":
    sys.exit(main())
