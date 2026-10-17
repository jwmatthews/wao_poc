"""Exercise tag updates and generated-file verification without a registry or cluster."""

import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BINDINGS = pathlib.Path("internal/components/zz_generated.images.go")


class OperandManifestsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        for name in ("api", "config", "internal", "bundle", "hack"):
            shutil.copytree(ROOT / name, self.root / name)
        for name in ("Makefile", "release-set.yaml", "go.mod", "go.sum"):
            shutil.copy2(ROOT / name, self.root / name)
        for name in ("bin", "vendor"):
            if (ROOT / name).is_dir():
                (self.root / name).symlink_to(ROOT / name, target_is_directory=True)
        self.run_command("git", "init", "-q")

    def run_command(self, *args, check=True):
        env = dict(os.environ)
        for name in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "RELEASE_SET", "GIT_DIR", "GIT_WORK_TREE"):
            env.pop(name, None)
        # Dependencies must already be vendored or cached; these regressions stay offline.
        env.update(GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local")
        result = subprocess.run(args, cwd=self.root, env=env, capture_output=True,
                                text=True, timeout=120)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def change_tags(self):
        release_set = json.loads(self.run_command(
            str(ROOT / "bin/yq"), "-o=json", ".", "release-set.yaml").stdout)
        for index, (name, component) in enumerate(release_set["components"].items()):
            tag = f"v9.8.{index}-test"
            component["tag"] = tag
            for image in component["images"].values():
                image["tagged"] = image["tagged"].rsplit(":", 1)[0] + ":" + tag
            stamp = {key: component[key] for key in ("repo", "tag", "commit")}
            (self.root / f"config/operands/{name}/UPSTREAM.yaml").write_text(json.dumps(stamp))
        (self.root / "release-set.yaml").write_text(json.dumps(release_set))

    def test_tag_changes_regenerate_bindings_without_editing_component_definitions(self):
        definitions = {path: path.read_bytes() for path in
                       (self.root / "internal/components").glob("*.go")
                       if path.name in {"nhc.go", "snr.go", "sbr.go", "far.go", "mdr.go", "nmo.go"}}
        self.change_tags()
        self.run_command("make", "-s", "operand-manifests")
        self.run_command("go", "test", "./internal/components", "./internal/operands", "-count=1")
        for path, content in definitions.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def test_verification_accepts_unstaged_generated_updates(self):
        self.run_command("git", "add", "config", "internal")
        self.change_tags()
        self.run_command("make", "-s", "operand-manifests")
        self.run_command("make", "-s", "verify-operand-manifests")

    def test_verification_rejects_stale_bindings(self):
        self.run_command("make", "-s", "operand-manifests")
        path = self.root / BINDINGS
        self.assertTrue(path.is_file(), "operand-manifests did not generate Go image bindings")
        content, count = re.subn(r'("RELATED_IMAGE_NHC_MANAGER":\s*")[^"]+',
                                 r'\1example.test/nhc:stale', path.read_text())
        self.assertEqual(count, 1)
        path.write_text(content)
        result = self.run_command("make", "-s", "verify-operand-manifests", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("generated", result.stdout + result.stderr)

    def test_generator_rejects_missing_tagged_reference_without_overwriting_bindings(self):
        self.run_command("make", "-s", "operand-manifests")
        before = (self.root / BINDINGS).read_bytes()
        release_set = json.loads(self.run_command(
            str(ROOT / "bin/yq"), "-o=json", ".", "release-set.yaml").stdout)
        del release_set["components"]["nhc"]["images"]["RELATED_IMAGE_NHC_MANAGER"]["tagged"]
        (self.root / "release-set.yaml").write_text(json.dumps(release_set))
        result = self.run_command("bash", "hack/generate-image-bindings.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonempty tagged reference", result.stderr)
        self.assertEqual((self.root / BINDINGS).read_bytes(), before)

    def test_bump_runs_steps_in_order_under_parallel_make_and_stops_on_failure(self):
        log = self.root / "steps.log"
        steps = ["update-release-set", "update-operand-manifests", "verify-operand-manifests"]
        for index, step in enumerate(steps):
            script = self.root / f"hack/{step}.sh"
            previous = steps[index - 1] if index else None
            script.write_text("#!/usr/bin/env python3\n"
                              "import os, pathlib, sys, time\n"
                              f"step, previous = {step!r}, {previous!r}\n"
                              f"with pathlib.Path({str(log)!r}).open('a') as log:\n"
                              "    log.write(step + '\\n')\n"
                              "if previous and not pathlib.Path('.completed-' + previous).exists():\n"
                              "    sys.exit('previous step has not completed: ' + previous)\n"
                              "if step == os.environ.get('FAIL_STEP'):\n"
                              "    sys.exit(1)\n"
                              "time.sleep(0.15)\n"
                              "pathlib.Path('.completed-' + step).touch()\n")
            script.chmod(0o755)
        self.run_command("make", "-j4", "bump-operands")
        self.assertEqual(log.read_text().splitlines(),
                         steps)
        log.unlink()
        for step in steps:
            (self.root / f".completed-{step}").unlink()
        result = self.run_command("make", "-j4", "bump-operands",
                                  "FAIL_STEP=update-operand-manifests", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(log.read_text().splitlines(),
                         ["update-release-set", "update-operand-manifests"])

    def test_generator_rejects_duplicate_environment_names(self):
        release_set = json.loads(self.run_command(
            str(ROOT / "bin/yq"), "-o=json", ".", "release-set.yaml").stdout)
        release_set["components"]["snr"]["images"].update(release_set["components"]["nhc"]["images"])
        (self.root / "release-set.yaml").write_text(json.dumps(release_set))
        before = (self.root / BINDINGS).read_bytes()
        result = self.run_command("bash", "hack/generate-image-bindings.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be unique", result.stderr)
        self.assertEqual((self.root / BINDINGS).read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
