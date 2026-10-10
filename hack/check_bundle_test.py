# hack/check_bundle_test.py
import pathlib, shutil, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
CSV_NAME = "workload-availability-operator.clusterserviceversion.yaml"


def check(bundle_dir):
    return subprocess.run([sys.executable, str(HERE / "check-bundle.py"), str(bundle_dir), str(REPO / "release-set.yaml")],
                          capture_output=True, text=True)


class CheckBundleTest(unittest.TestCase):
    def setUp(self):
        if not (REPO / "bundle").exists():
            self.skipTest("bundle not generated")
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.bundle = self.tmp / "bundle"
        shutil.copytree(REPO / "bundle", self.bundle)
        self.csv_path = self.bundle / "manifests" / CSV_NAME
        self.csv = yaml.safe_load(self.csv_path.read_text())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def save(self):
        self.csv_path.write_text(yaml.safe_dump(self.csv, sort_keys=False, width=4096))

    def test_committed_bundle_passes(self):
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("bundle OK", proc.stdout)

    def test_webhookdefinitions_rejected(self):
        self.csv["spec"]["webhookdefinitions"] = [{"type": "ValidatingAdmissionWebhook", "admissionReviewVersions": ["v1"],
                                                   "deploymentName": "x", "generateName": "x.kb.io", "sideEffects": "None"}]
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("webhookdefinitions", proc.stdout)

    def test_owned_apiservice_rejected(self):
        self.csv["spec"]["apiservicedefinitions"] = {"owned": [{"group": "g", "version": "v1", "kind": "K", "name": "v1.g",
                                                                "deploymentName": "x"}]}
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("apiservicedefinitions", proc.stdout)

    def test_non_semver_version_rejected(self):
        self.csv["spec"]["version"] = "0.1"
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("semver", proc.stdout)

    def test_dependencies_file_rejected(self):
        (self.bundle / "metadata" / "dependencies.yaml").write_text("dependencies: []\n")
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("dependencies.yaml", proc.stdout)

    def test_required_property_rejected(self):
        (self.bundle / "metadata" / "properties.yaml").write_text(yaml.safe_dump(
            {"properties": [{"type": "olm.package.required", "value": {"packageName": "x", "versionRange": ">=1.0.0"}}]}))
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("olm.package.required", proc.stdout)

    def test_extra_object_rejected(self):
        (self.bundle / "manifests" / "extra.yaml").write_text(yaml.safe_dump(
            {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "extra"}, "data": {}}))
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("ConfigMap/extra", proc.stdout)
        self.assertNotIn("ConfigMap catalog", proc.stdout)


if __name__ == "__main__":
    unittest.main()
