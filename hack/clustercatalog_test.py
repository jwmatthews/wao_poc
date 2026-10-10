# hack/clustercatalog_test.py
import pathlib, subprocess, sys, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
IMG = "image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-catalog@sha256:" + "b" * 64


def render(image=IMG):
    return subprocess.run([sys.executable, str(HERE / "clustercatalog.py"), "--name", "wao-poc", "--image", image],
                          capture_output=True, text=True)


class ClusterCatalogTest(unittest.TestCase):
    def test_manifest(self):
        proc = render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        obj = yaml.safe_load(proc.stdout)
        self.assertEqual(obj["apiVersion"], "olm.operatorframework.io/v1")
        self.assertEqual(obj["kind"], "ClusterCatalog")
        self.assertEqual(obj["metadata"]["name"], "wao-poc")
        self.assertEqual(obj["spec"], {"availabilityMode": "Available", "priority": 0,
                                       "source": {"type": "Image", "image": {"ref": IMG}}})
        # A digest reference must not carry pollIntervalMinutes (CRD validation rejects it).
        self.assertNotIn("pollIntervalMinutes", proc.stdout)

    def test_rejects_tag_reference(self):
        proc = render(image="quay.io/example/wao-catalog:latest")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("digest", proc.stderr)


class GeneratedManifestsTest(unittest.TestCase):
    """config/olmv1/wao is generated; its headers must not embed a workstation path."""

    def test_no_absolute_paths_in_generated_files(self):
        files = list((HERE.parent / "config" / "olmv1" / "wao").glob("*.yaml"))
        self.assertEqual(len(files), 5, files)
        for f in files:
            for line in f.read_text().splitlines():
                self.assertNotRegex(line, r"(/Users/|/home/)", f"{f}: {line}")

    def test_clusterextension_pins_catalog_and_version(self):
        ce = yaml.safe_load((HERE.parent / "config" / "olmv1" / "wao" / "30-clusterextension.yaml").read_text())
        self.assertEqual(ce["metadata"]["name"], "workload-availability-operator")
        self.assertEqual(ce["spec"]["namespace"], "openshift-workload-availability")
        self.assertEqual(ce["spec"]["serviceAccount"], {"name": "wao-installer"})
        cat = ce["spec"]["source"]["catalog"]
        self.assertEqual(cat["packageName"], "workload-availability-operator")
        self.assertEqual(cat["channels"], ["alpha"])
        self.assertEqual(cat["version"], "0.1.0")
        self.assertEqual(cat["upgradeConstraintPolicy"], "CatalogProvided")
        self.assertEqual(cat["selector"], {"matchLabels": {"olm.operatorframework.io/metadata.name": "wao-poc"}})

    def test_namespace_manifest(self):
        ns = yaml.safe_load((HERE.parent / "config" / "olmv1" / "namespace.yaml").read_text())
        self.assertEqual(ns["metadata"]["name"], "openshift-workload-availability")
        self.assertEqual(ns["metadata"]["annotations"]["openshift.io/node-selector"], "")
        labels = ns["metadata"]["labels"]
        for key in ("pod-security.kubernetes.io/enforce", "pod-security.kubernetes.io/audit", "pod-security.kubernetes.io/warn"):
            self.assertEqual(labels[key], "privileged")
        self.assertEqual(labels["security.openshift.io/scc.podSecurityLabelSync"], "false")


if __name__ == "__main__":
    unittest.main()
