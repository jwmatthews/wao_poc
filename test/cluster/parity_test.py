# test/cluster/parity_test.py — offline checks: extracted operand manifests must be parity-clean.
import copy, importlib.util, pathlib, unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("parity", HERE / "parity.py")
parity = importlib.util.module_from_spec(spec); spec.loader.exec_module(parity)

COMPONENTS = ("nhc", "snr", "sbr", "far", "mdr", "nmo")


@unittest.skipUnless((REPO / ".cache/bundles/nhc/fetch.json").exists(), "run `make bundles` first")
class ParityTest(unittest.TestCase):
    def setUp(self):
        self.release_set = yaml.safe_load((REPO / "release-set.yaml").read_text())

    def rendered(self, component, name):
        f = REPO / "internal/operands/manifests" / component / f"50-Deployment-{name}.yaml"
        images = parity.image_map(self.release_set, component)
        return parity.pin(yaml.safe_load(f.read_text()), images)  # what WAO applies

    def test_extracted_deployments_match_bundle(self):
        for comp in COMPONENTS:
            images = parity.image_map(self.release_set, comp)
            for d in parity.bundle_csv(comp)["spec"]["install"]["spec"]["deployments"]:
                live = self.rendered(comp, d["name"])
                self.assertEqual(parity.compare_deployment(d, live["spec"], images), 0, f"{comp}/{d['name']}")

    def test_extracted_cluster_roles_match_bundle(self):
        for comp in COMPONENTS:
            for p in parity.bundle_csv(comp)["spec"]["install"]["spec"].get("clusterPermissions") or []:
                f = REPO / "internal/operands/manifests" / comp / f"10-ClusterRole-{p['serviceAccountName']}.yaml"
                live = yaml.safe_load(f.read_text())
                self.assertEqual(parity.compare_rules(p["serviceAccountName"], p["rules"], live["rules"]), 0, comp)

    def test_extracted_namespaced_permissions_are_granted_cluster_wide(self):
        # OLM copies CSV `permissions` into a ClusterRole/ClusterRoleBinding for an AllNamespaces OperatorGroup
        # and appends get/list/watch on namespaces to the copy.
        for comp in COMPONENTS:
            perms = parity.bundle_csv(comp)["spec"]["install"]["spec"].get("permissions") or []
            self.assertTrue(perms, comp)
            for p in perms:
                sa, name = p["serviceAccountName"], parity.all_namespaces_name(p["serviceAccountName"])
                d = REPO / "internal/operands/manifests" / comp
                role = yaml.safe_load((d / f"20-Role-{sa}.yaml").read_text())
                self.assertEqual(parity.compare_rules(sa, p["rules"], role["rules"], kind="Role"), 0, comp)
                cr = yaml.safe_load((d / f"10-ClusterRole-{name}.yaml").read_text())
                self.assertEqual(parity.compare_rules(name, parity.all_namespaces_rules(p["rules"]), cr["rules"]), 0, comp)
                self.assertEqual(parity.compare_rules(name, p["rules"], cr["rules"]), 1, f"{comp}: OLM namespaces rule missing")
                crb = yaml.safe_load((d / f"11-ClusterRoleBinding-{name}.yaml").read_text())
                self.assertEqual(parity.compare_binding(name, name, sa, "__WAO_NAMESPACE__", crb), 0, comp)

    def test_detects_wrong_binding_subject(self):
        live = {"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "x-all-namespaces"},
                "subjects": [{"kind": "ServiceAccount", "name": "x", "namespace": "other"}]}
        self.assertEqual(parity.compare_binding("x-all-namespaces", "x-all-namespaces", "x", "ns", live), 1)

    def test_all_namespaces_rules_append_olm_namespaces_rule(self):
        rules = [{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get"]}]
        self.assertEqual(parity.all_namespaces_rules(rules),
                         rules + [{"apiGroups": [""], "resources": ["namespaces"], "verbs": ["get", "list", "watch"]}])
        self.assertEqual(len(rules), 1, "input not mutated")

    def test_detects_changed_rules(self):
        p = parity.bundle_csv("nhc")["spec"]["install"]["spec"]["clusterPermissions"][0]
        live = copy.deepcopy(p["rules"])
        live.append({"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]})
        self.assertEqual(parity.compare_rules(p["serviceAccountName"], p["rules"], live), 1)

    def test_detects_changed_args(self):
        images = parity.image_map(self.release_set, "snr")
        d = parity.bundle_csv("snr")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("snr", d["name"]))
        live["spec"]["template"]["spec"]["containers"][0]["args"].append("--extra")
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 1)

    def test_detects_unpinned_image(self):
        images = parity.image_map(self.release_set, "nhc")
        d = parity.bundle_csv("nhc")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("nhc", d["name"]))
        live["spec"]["template"]["spec"]["containers"][0]["image"] = "quay.io/medik8s/node-healthcheck-operator:v0.12.0"
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 1)

    def test_ignores_api_server_defaults(self):
        images = parity.image_map(self.release_set, "snr")
        d = parity.bundle_csv("snr")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("snr", d["name"]))
        c = live["spec"]["template"]["spec"]["containers"][0]
        c["livenessProbe"]["timeoutSeconds"] = 1
        c["imagePullPolicy"] = "IfNotPresent"
        for e in c["env"]:
            if "valueFrom" in e:
                e["valueFrom"]["fieldRef"]["apiVersion"] = "v1"
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 0)


if __name__ == "__main__":
    unittest.main()
