# hack/configmap_catalog_test.py
import json, pathlib, subprocess, sys, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = HERE.parent / "bundle"


class CatalogTest(unittest.TestCase):
    def setUp(self):
        if not BUNDLE.exists():
            self.skipTest("bundle not generated")
        out = subprocess.run([sys.executable, str(HERE / "configmap-catalog.py"), "--bundle", str(BUNDLE),
                              "--package", "workload-availability-operator", "--channel", "alpha",
                              "--name", "wao-poc-catalog", "--namespace", "openshift-marketplace"],
                             check=True, capture_output=True, text=True).stdout
        self.docs = list(yaml.safe_load_all(out))

    def test_configmap_and_catalogsource(self):
        cm = next(d for d in self.docs if d["kind"] == "ConfigMap")
        cs = next(d for d in self.docs if d["kind"] == "CatalogSource")
        self.assertEqual(cm["metadata"]["namespace"], "openshift-marketplace")
        self.assertEqual(cs["spec"], {"sourceType": "internal", "configMap": "wao-poc-catalog",
                                      "displayName": "WAO POC catalog", "publisher": "wao_poc"})
        crds = json.loads(cm["data"]["customResourceDefinitions"])
        csvs = json.loads(cm["data"]["clusterServiceVersions"])
        pkgs = json.loads(cm["data"]["packages"])
        # Twelve component CRDs plus the WorkloadAvailabilityConfig CRD, all owned by the WAO CSV.
        self.assertEqual(len(crds), 13)
        self.assertEqual(len(csvs), 1)
        self.assertEqual(pkgs, [{"packageName": "workload-availability-operator", "defaultChannel": "alpha",
                                 "channels": [{"name": "alpha", "currentCSV": csvs[0]["metadata"]["name"]}]}])
        self.assertLess(sum(len(v) for v in cm["data"].values()), 900 * 1024, "ConfigMap size budget")


if __name__ == "__main__":
    unittest.main()
