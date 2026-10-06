"""Exercise the Kind runner without Docker or a Kubernetes connection."""
import fcntl
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
RUNNER = REPO / "test/e2e/run.py"


class E2ERunnerTest(unittest.TestCase):
    def run_runner(self, *, test_exit=0, create_exit=0, existing=False, delete_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = root / "bin"
            tools.mkdir()
            log = root / "commands"
            kind = tools / "kind"
            kind.write_text('''#!/usr/bin/env bash
printf 'kind %s\\n' "$*" >> "$COMMAND_LOG"
case "$1 $2" in
  'get clusters') printf '%s\\n' "$EXISTING_CLUSTER" ;;
  'create cluster') exit "$CREATE_EXIT" ;;
  'delete cluster') exit "$DELETE_EXIT" ;;
esac
''')
            go = tools / "go"
            go.write_text('''#!/usr/bin/env bash
printf 'go %s\\n' "$*" >> "$COMMAND_LOG"
printf 'kubeconfig %s\\n' "$KUBECONFIG" >> "$COMMAND_LOG"
exit "$TEST_EXIT"
''')
            kind.chmod(0o755)
            go.chmod(0o755)
            run_dir = root / "evidence"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       KIND=str(kind), KIND_CLUSTER="wao-ci-test", RUN_DIR=str(run_dir),
                       KUBECONFIG="/do-not-use/current-cluster", COMMAND_LOG=str(log),
                       TEST_EXIT=str(test_exit), CREATE_EXIT=str(create_exit),
                       DELETE_EXIT=str(delete_exit),
                       EXISTING_CLUSTER="wao-ci-test" if existing else "")
            result = subprocess.run([sys.executable, str(RUNNER)], cwd=REPO, env=env,
                                    capture_output=True, text=True, timeout=10)
            commands = log.read_text() if log.exists() else ""
            return result, commands, str((run_dir / "kubeconfig").resolve())

    def test_success_uses_isolated_kubeconfig_and_deletes_cluster(self):
        result, commands, kubeconfig = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--kubeconfig {kubeconfig}", commands)
        self.assertIn(f"kubeconfig {kubeconfig}", commands)
        self.assertNotIn("/do-not-use/current-cluster", commands)
        self.assertIn("go test ./test/e2e/", commands)
        self.assertTrue(commands.rstrip().endswith("kind delete cluster --name wao-ci-test"))

    def test_test_failure_is_preserved_and_cluster_is_deleted(self):
        result, commands, _ = self.run_runner(test_exit=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("kind delete cluster --name wao-ci-test", commands)

    def test_partial_creation_is_cleaned_up(self):
        result, commands, _ = self.run_runner(create_exit=4)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertNotIn("go test", commands)
        self.assertIn("kind delete cluster --name wao-ci-test", commands)

    def test_existing_cluster_is_never_reused_or_deleted(self):
        result, commands, _ = self.run_runner(existing=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("kind get clusters", commands)
        self.assertNotIn("kind create", commands)
        self.assertNotIn("kind delete", commands)
        self.assertNotIn("go test", commands)

    def test_cleanup_failure_fails_otherwise_successful_run(self):
        result, commands, _ = self.run_runner(delete_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("go test", commands)
        self.assertIn("kind delete", commands)

    def test_concurrent_run_cannot_use_or_delete_reserved_cluster(self):
        lock_path = pathlib.Path(tempfile.gettempdir()) / f"wao-kind-{os.getuid()}-wao-ci-test.lock"
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result, commands, _ = self.run_runner()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(commands, "")

    def test_hung_command_has_wall_clock_timeout(self):
        spec = importlib.util.spec_from_file_location("e2e_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryFile(mode="w+") as log:
            started = time.monotonic()
            code = runner.run([sys.executable, "-c", "import time; time.sleep(60)"], 0.1, log)
            self.assertEqual(code, 124)
            self.assertLess(time.monotonic() - started, 3)

    def test_exited_command_does_not_leave_background_children(self):
        spec = importlib.util.spec_from_file_location("e2e_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile(mode="w+") as log:
            ready = pathlib.Path(directory) / "ready"
            leaked = pathlib.Path(directory) / "leaked"
            child = ("import pathlib,time; "
                     f"pathlib.Path({str(ready)!r}).touch(); "
                     f"time.sleep(0.5); pathlib.Path({str(leaked)!r}).touch()")
            parent = ("import pathlib,subprocess,sys,time; "
                      f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
                      f"ready=pathlib.Path({str(ready)!r})\n"
                      "while not ready.exists(): time.sleep(0.01)\n"
                      "sys.exit(1)")
            self.assertEqual(runner.run([sys.executable, "-c", parent], 5, log), 1)
            self.assertTrue(ready.exists())
            time.sleep(0.7)
            self.assertFalse(leaked.exists(), "background child survived its command")


if __name__ == "__main__":
    unittest.main()
