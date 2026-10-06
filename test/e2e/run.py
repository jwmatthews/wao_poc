#!/usr/bin/env python3
"""Run the all-Disabled smoke test in a new Kind cluster with bounded cleanup."""
import datetime
import fcntl
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import uuid


REPO = pathlib.Path(__file__).resolve().parents[2]


def run(command, timeout, log, *, stdout=None):
    """Bound the whole command, including its subprocesses on timeout/interruption."""
    print(f"running: {command}", file=log, flush=True)
    with subprocess.Popen(command, cwd=REPO, stdout=stdout or log, stderr=log,
                          start_new_session=True) as process:
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"command timed out after {timeout}s", file=log, flush=True)
            return 124
        finally:
            # A timed-out make command inside Go may leave Docker children even
            # after go test itself exits. Always reap the group this runner owns.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main():
    kind = os.environ.get("KIND", "kind")
    cluster = os.environ.get("KIND_CLUSTER") or f"wao-e2e-{uuid.uuid4().hex[:12]}"
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", cluster):
        print("KIND_CLUSTER must contain lowercase letters, digits and internal hyphens", file=sys.stderr)
        return 2
    date = datetime.datetime.now(datetime.timezone.utc).date()
    run_dir = pathlib.Path(os.environ.get("RUN_DIR") or REPO / "evidence" / f"{date}-kind-e2e-{os.getpid()}")
    run_dir = run_dir.resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    os.environ.update(KIND_CLUSTER=cluster, RUN_DIR=str(run_dir), KUBECONFIG=str(run_dir / "kubeconfig"))
    print(f"Kind E2E output: {run_dir / 'e2e.log'}", flush=True)

    # Serialize explicit names across worktrees on this host. Keep the lock file
    # after releasing it: unlinking a locked file would allow a second lock inode.
    lock_path = pathlib.Path(tempfile.gettempdir()) / f"wao-kind-{os.getuid()}-{cluster}.lock"
    with lock_path.open("a") as lock, (run_dir / "e2e.log").open("a") as log:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another E2E run owns this Kind cluster name; choose a different KIND_CLUSTER", file=sys.stderr)
            return 2
        with (run_dir / "clusters.txt").open("w+") as clusters:
            code = run([kind, "get", "clusters"], 30, log, stdout=clusters)
            if code:
                return code
            clusters.seek(0)
            if cluster in clusters.read().splitlines():
                print("Refusing to reuse or delete an existing Kind cluster; choose another KIND_CLUSTER", file=sys.stderr)
                return 2

        code = 1
        try:
            code = run([kind, "create", "cluster", "--name", cluster,
                        "--kubeconfig", os.environ["KUBECONFIG"], "--wait", "120s"], 300, log)
            if code == 0:
                # This timeout also bounds Go compilation, before the Go test timer starts.
                code = run(["go", "test", "./test/e2e/", "-count=1", "-timeout=20m", "-v", "-ginkgo.v"], 1500, log)
        except KeyboardInterrupt:
            code = 130
        except OSError as error:
            print(error, file=log)
            code = 1
        finally:
            cleanup_code = run([kind, "delete", "cluster", "--name", cluster], 120, log)
            if cleanup_code and code == 0:
                code = cleanup_code
        print(f"Kind E2E {'passed' if code == 0 else 'failed'} (exit {code}); diagnostics: {run_dir / 'e2e.log'}")
        return code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
