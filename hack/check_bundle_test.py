# hack/check_bundle_test.py
import pathlib, shutil, subprocess, sys, tempfile, unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
SCRIPT = HERE / "check-bundle.py"
UNION = REPO / "config/rbac/operand_union_role.yaml"


def union_rules():
    return next(d for d in yaml.safe_load_all(UNION.read_text()) if d["kind"] == "ClusterRole")["rules"]


def check(bundle):
    return subprocess.run([sys.executable, str(SCRIPT), str(bundle), str(REPO / "release-set.yaml")],
                          capture_output=True, text=True)


def csv_path(bundle):
    return next(p for p in sorted(pathlib.Path(bundle, "manifests").glob("*.yaml"))
                if yaml.safe_load(p.read_text())["kind"] == "ClusterServiceVersion")


def key(rule):
    return tuple(tuple(sorted(rule.get(k) or [])) for k in ("apiGroups", "resources", "resourceNames", "verbs"))


class CheckBundleTest(unittest.TestCase):
    def test_committed_bundle_passes_and_reports_rule_count(self):
        r = check(REPO / "bundle")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        n = len(union_rules())
        self.assertIn(f"{n} union-role rules", r.stdout)

    def test_csv_missing_a_union_role_rule_fails_naming_it(self):
        with tempfile.TemporaryDirectory() as d:
            bundle = pathlib.Path(d) / "bundle"
            shutil.copytree(REPO / "bundle", bundle)
            p = csv_path(bundle)
            csv = yaml.safe_load(p.read_text())
            union = union_rules()
            victim = union[0]
            perms = csv["spec"]["install"]["spec"]["clusterPermissions"]
            for perm in perms:
                perm["rules"] = [r for r in perm["rules"] if key(r) != key(victim)]
            p.write_text(yaml.safe_dump(csv))
            r = check(bundle)
            self.assertNotEqual(r.returncode, 0)
            out = r.stdout + r.stderr
            self.assertIn("union role rule missing from CSV clusterPermissions", out)
            self.assertIn(victim["resources"][0], out)


if __name__ == "__main__":
    unittest.main()
