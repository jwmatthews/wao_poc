# hack/bundle_annotations_test.py
import pathlib, shutil, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent


class BundleAnnotationsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        (self.tmp / "bundle" / "metadata").mkdir(parents=True)
        (self.tmp / "bundle" / "metadata" / "annotations.yaml").write_text(yaml.safe_dump(
            {"annotations": {"operators.operatorframework.io.bundle.package.v1": "workload-availability-operator"}}))
        (self.tmp / "bundle.Dockerfile").write_text("FROM scratch\nLABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1\nCOPY bundle/manifests /manifests/\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_it(self):
        return subprocess.run([sys.executable, str(HERE / "bundle-annotations.py"), "--bundle", str(self.tmp / "bundle"),
                               "--dockerfile", str(self.tmp / "bundle.Dockerfile"), "--openshift-versions", "v4.18"],
                              capture_output=True, text=True, check=True)

    def test_adds_versions_annotation_and_label_once(self):
        self.run_it()
        self.run_it()  # idempotent
        ann = yaml.safe_load((self.tmp / "bundle" / "metadata" / "annotations.yaml").read_text())["annotations"]
        self.assertEqual(ann["com.redhat.openshift.versions"], "v4.18")
        self.assertEqual(ann["operators.operatorframework.io.bundle.package.v1"], "workload-availability-operator")
        text = (self.tmp / "bundle.Dockerfile").read_text()
        self.assertEqual(text.count('LABEL com.redhat.openshift.versions="v4.18"'), 1)
        self.assertLess(text.index("LABEL com.redhat.openshift.versions"), text.index("COPY "), "label before COPY lines")


class CommittedBundleTest(unittest.TestCase):
    def setUp(self):
        if not (REPO / "bundle").exists():
            self.skipTest("bundle not generated")

    def test_committed_bundle_carries_openshift_metadata(self):
        ann = yaml.safe_load((REPO / "bundle" / "metadata" / "annotations.yaml").read_text())["annotations"]
        self.assertEqual(ann.get("com.redhat.openshift.versions"), "v4.18")
        self.assertIn('LABEL com.redhat.openshift.versions="v4.18"', (REPO / "bundle.Dockerfile").read_text())
        csv = yaml.safe_load((REPO / "bundle" / "manifests" / "workload-availability-operator.clusterserviceversion.yaml").read_text())
        a = csv["metadata"]["annotations"]
        expected = {"disconnected": "true", "fips-compliant": "false", "proxy-aware": "false", "tls-profiles": "false",
                    "token-auth-aws": "false", "token-auth-azure": "false", "token-auth-gcp": "false",
                    "cnf": "false", "cni": "false", "csi": "false"}
        for key, value in expected.items():
            self.assertEqual(a.get(f"features.operators.openshift.io/{key}"), value, key)


if __name__ == "__main__":
    unittest.main()
