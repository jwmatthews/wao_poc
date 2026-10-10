# hack/fbc_catalog_test.py
import json, pathlib, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = HERE.parent / "bundle"
BUNDLE_IMG = "image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-bundle@sha256:" + "a" * 64


def render(bundle=BUNDLE, image=BUNDLE_IMG):
    out = tempfile.mkdtemp()
    proc = subprocess.run([sys.executable, str(HERE / "fbc-catalog.py"), "--bundle", str(bundle),
                           "--bundle-image", image, "--out", out], capture_output=True, text=True)
    return proc, pathlib.Path(out)


class FBCTest(unittest.TestCase):
    def setUp(self):
        if not BUNDLE.exists():
            self.skipTest("bundle not generated")

    def blobs(self, out):
        path = out / "workload-availability-operator" / "catalog.json"
        self.assertTrue(path.exists(), f"{path} missing")
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def test_package_channel_and_bundle(self):
        proc, out = render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        blobs = self.blobs(out)
        by_schema = {b["schema"]: b for b in blobs}
        self.assertEqual(set(by_schema), {"olm.package", "olm.channel", "olm.bundle"})
        self.assertEqual(by_schema["olm.package"], {"schema": "olm.package", "name": "workload-availability-operator",
                                                    "defaultChannel": "alpha"})
        self.assertEqual(by_schema["olm.channel"]["entries"], [{"name": "workload-availability-operator.v0.1.0"}])
        bundle = by_schema["olm.bundle"]
        self.assertEqual(bundle["name"], "workload-availability-operator.v0.1.0")
        self.assertEqual(bundle["image"], BUNDLE_IMG)
        props = {p["type"]: p for p in bundle["properties"] if p["type"] != "olm.gvk"}
        self.assertEqual(props["olm.package"]["value"], {"packageName": "workload-availability-operator", "version": "0.1.0"})
        gvks = [p["value"] for p in bundle["properties"] if p["type"] == "olm.gvk"]
        # Twelve component CRDs plus the WorkloadAvailabilityConfig CRD, one olm.gvk each.
        self.assertEqual(len(gvks), 13)
        self.assertIn({"group": "workloadavailability.medik8s.io", "kind": "WorkloadAvailabilityConfig", "version": "v1alpha1"}, gvks)
        self.assertEqual(props["olm.csv.metadata"]["value"]["installModes"],
                         [{"type": "OwnNamespace", "supported": False}, {"type": "SingleNamespace", "supported": False},
                          {"type": "MultiNamespace", "supported": False}, {"type": "AllNamespaces", "supported": True}])
        # No dependency properties: OLM v1 rejects them.
        self.assertFalse({"olm.package.required", "olm.gvk.required", "olm.constraint"} & set(props))
        # relatedImages carries the CSV relatedImages (pinned operand images) plus the bundle image.
        images = {r["image"] for r in bundle["relatedImages"]}
        self.assertIn(BUNDLE_IMG, images)
        self.assertTrue(all("@sha256:" in i for i in images), images)

    def test_rejects_tag_reference(self):
        proc, _ = render(image="quay.io/example/wao-bundle:v0.1.0")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("digest", proc.stderr)

    def test_rejects_bundle_without_one_csv(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "manifests").mkdir()
            (pathlib.Path(d) / "metadata").mkdir()
            (pathlib.Path(d) / "metadata" / "annotations.yaml").write_text(
                yaml.safe_dump({"annotations": {"operators.operatorframework.io.bundle.package.v1": "x",
                                                "operators.operatorframework.io.bundle.channel.default.v1": "alpha",
                                                "operators.operatorframework.io.bundle.channels.v1": "alpha"}}))
            proc, _ = render(bundle=d)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("exactly one CSV", proc.stderr)

    def test_catalog_dockerfile_serves_configs(self):
        text = (HERE.parent / "catalog.Dockerfile").read_text()
        self.assertIn("FROM scratch", text)
        self.assertIn("LABEL operators.operatorframework.io.index.configs.v1=/configs", text)
        self.assertIn("COPY dist/catalog /configs", text)
        dockerignore = (HERE.parent / ".dockerignore").read_text()
        self.assertIn("!dist/catalog", dockerignore)


if __name__ == "__main__":
    unittest.main()
