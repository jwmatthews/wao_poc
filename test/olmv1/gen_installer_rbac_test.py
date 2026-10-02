"""Unit tests for gen-installer-rbac.py (plain unittest, no cluster access).

Run:
    .venv/bin/python test/olmv1/gen_installer_rbac_test.py -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_generator():
    spec = importlib.util.spec_from_file_location("gen_installer_rbac", os.path.join(HERE, "gen-installer-rbac.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load_generator()


def _rule_covers(have: dict, want: dict) -> bool:
    """True when ClusterRole rule `have` grants everything in CSV rule `want`."""
    def _all(h, w):
        return "*" in h or all(x in h for x in w)
    if "nonResourceURLs" in want:
        return "nonResourceURLs" in have and _all(have["nonResourceURLs"], want["nonResourceURLs"]) \
            and _all(have["verbs"], want["verbs"])
    if "nonResourceURLs" in have:
        return False
    if not (_all(have.get("apiGroups", []), want.get("apiGroups", [])) and
            _all(have.get("resources", []), want.get("resources", [])) and
            _all(have.get("verbs", []), want.get("verbs", []))):
        return False
    if have.get("resourceNames"):
        return bool(want.get("resourceNames")) and all(n in have["resourceNames"] for n in want["resourceNames"])
    return True


class GeneratorOutputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = {op["key"]: gen.generate(op) for op in gen.OPERATORS}

    def _manifest(self, key: str, name: str) -> dict:
        docs = [d for d in yaml.safe_load_all(self.results[key]["manifests"][name]) if d]
        self.assertEqual(len(docs), 1, f"{key}/{name} should hold exactly one document")
        return docs[0]

    def test_six_operators_each_yield_four_manifests_plus_kustomization(self):
        self.assertEqual(sorted(self.results), ["far", "mdr", "nhc", "nmo", "sbr", "snr", "wao"])
        for key, r in self.results.items():
            self.assertEqual(
                sorted(r["manifests"]),
                ["00-serviceaccount.yaml", "10-clusterrole.yaml", "20-clusterrolebinding.yaml",
                 "30-clusterextension.yaml", "kustomization.yaml"], key)
            kinds = [self._manifest(key, n)["kind"] for n in
                     ("00-serviceaccount.yaml", "10-clusterrole.yaml", "20-clusterrolebinding.yaml", "30-clusterextension.yaml")]
            self.assertEqual(kinds, ["ServiceAccount", "ClusterRole", "ClusterRoleBinding", "ClusterExtension"], key)
            kust = self._manifest(key, "kustomization.yaml")
            self.assertEqual(kust["resources"], ["00-serviceaccount.yaml", "10-clusterrole.yaml",
                                                 "20-clusterrolebinding.yaml", "30-clusterextension.yaml"], key)

    def test_names_and_namespace_wire_together(self):
        for key in self.results:
            sa = self._manifest(key, "00-serviceaccount.yaml")
            cr = self._manifest(key, "10-clusterrole.yaml")
            crb = self._manifest(key, "20-clusterrolebinding.yaml")
            ce = self._manifest(key, "30-clusterextension.yaml")
            self.assertEqual(sa["metadata"]["name"], f"{key}-installer")
            self.assertEqual(sa["metadata"]["namespace"], "openshift-workload-availability")
            self.assertEqual(cr["metadata"]["name"], f"{key}-installer-clusterrole")
            self.assertEqual(crb["roleRef"]["name"], cr["metadata"]["name"])
            self.assertEqual(crb["subjects"], [{"kind": "ServiceAccount", "name": sa["metadata"]["name"],
                                               "namespace": sa["metadata"]["namespace"]}])
            self.assertEqual(ce["spec"]["serviceAccount"]["name"], sa["metadata"]["name"])
            self.assertEqual(ce["spec"]["namespace"], sa["metadata"]["namespace"])

    def test_clusterrole_has_finalizers_rule_scoped_to_extension_name(self):
        for key, r in self.results.items():
            cr = self._manifest(key, "10-clusterrole.yaml")
            ce = self._manifest(key, "30-clusterextension.yaml")
            fin = [x for x in cr["rules"] if x.get("resources") == ["clusterextensions/finalizers"]]
            self.assertEqual(len(fin), 1, key)
            self.assertEqual(fin[0]["apiGroups"], ["olm.operatorframework.io"])
            self.assertEqual(fin[0]["verbs"], ["update"])
            self.assertEqual(fin[0]["resourceNames"], [ce["metadata"]["name"]])
            self.assertEqual(ce["metadata"]["name"], r["op"]["package"])

    def test_every_csv_permission_rule_is_covered_by_the_clusterrole(self):
        for key, r in self.results.items():
            cr = self._manifest(key, "10-clusterrole.yaml")
            for section in ("permissions", "cluster_permissions"):
                for perm in r["info"][section]:
                    for want in perm["rules"]:
                        self.assertTrue(any(_rule_covers(h, want) for h in cr["rules"]),
                                        f"{key}: {section} rule not covered: {json.dumps(want)}")
            # bundle-shipped ClusterRole/Role rules too (the installer must hold what it grants)
            for o in r["others"]:
                if o["kind"] in ("ClusterRole", "Role"):
                    for want in o.get("rules") or []:
                        self.assertTrue(any(_rule_covers(h, gen.normalize_rule(want)) for h in cr["rules"]),
                                        f"{key}: bundle {o['kind']}/{o['metadata']['name']} rule not covered: {json.dumps(want)}")

    def test_crds_deployments_and_serviceaccounts_are_scoped_to_csv_names(self):
        for key, r in self.results.items():
            cr = self._manifest(key, "10-clusterrole.yaml")
            crd_manage = [x for x in cr["rules"] if x.get("resources") == ["customresourcedefinitions"] and "resourceNames" in x]
            self.assertEqual(len(crd_manage), 1, key)
            self.assertEqual(crd_manage[0]["resourceNames"], r["info"]["owned_crds"])
            self.assertEqual(crd_manage[0]["verbs"], ["get", "update", "patch", "delete"])
            dep_manage = [x for x in cr["rules"] if x.get("resources") == ["deployments"] and "resourceNames" in x]
            self.assertEqual(len(dep_manage), 1, key)
            self.assertEqual(dep_manage[0]["resourceNames"], sorted(r["info"]["deployments"]))
            sa_manage = [x for x in cr["rules"] if x.get("resources") == ["serviceaccounts"] and "resourceNames" in x]
            self.assertEqual(len(sa_manage), 1, key)
            for sa in r["info"]["service_accounts"]:
                self.assertIn(sa, sa_manage[0]["resourceNames"], key)

    def test_webhook_configurations_granted_when_csv_defines_webhooks(self):
        for key, r in self.results.items():
            cr = self._manifest(key, "10-clusterrole.yaml")
            types = {w["type"] for w in r["info"]["webhooks"]}
            has_v = any(x.get("resources") == ["validatingwebhookconfigurations"] for x in cr["rules"])
            has_m = any(x.get("resources") == ["mutatingwebhookconfigurations"] for x in cr["rules"])
            self.assertEqual(has_v, "ValidatingAdmissionWebhook" in types, key)
            self.assertEqual(has_m, "MutatingAdmissionWebhook" in types, key)
        self.assertTrue(any(w["type"] == "MutatingAdmissionWebhook" for w in self.results["far"]["info"]["webhooks"]))
        self.assertFalse(self.results["mdr"]["info"]["webhooks"])

    def test_escalate_and_bind_rules_present(self):
        for key in self.results:
            cr = self._manifest(key, "10-clusterrole.yaml")
            self.assertTrue(any(x["verbs"] == ["escalate"] and "clusterroles" in x["resources"] for x in cr["rules"]), key)
            self.assertTrue(any(x["verbs"] == ["bind"] and "clusterrolebindings" in x["resources"] for x in cr["rules"]), key)

    def test_clusterextension_version_is_pinned_exactly(self):
        heads = {"nhc": "0.12.1", "snr": "0.13.1", "far": "0.8.1", "mdr": "0.7.1", "nmo": "5.7.1", "sbr": "0.3.1",
                 "wao": "0.1.0"}
        # (channel, ClusterCatalog name); the six catalog operators share the Red Hat catalog, the POC has its own.
        sources = {k: ("stable", "openshift-redhat-operators") for k in heads}
        sources["wao"] = ("alpha", "wao-poc")
        for key, r in self.results.items():
            ce = self._manifest(key, "30-clusterextension.yaml")
            cat = ce["spec"]["source"]["catalog"]
            self.assertIsInstance(cat["version"], str, key)
            self.assertEqual(cat["version"], heads[key], key)
            self.assertRegex(cat["version"], r"^\d+\.\d+\.\d+$", key)  # exact, no range operators
            self.assertEqual(cat["channels"], [sources[key][0]], key)
            self.assertEqual(cat["packageName"], r["op"]["package"], key)
            self.assertEqual(ce["spec"]["source"]["sourceType"], "Catalog", key)
            self.assertEqual(cat["upgradeConstraintPolicy"], "CatalogProvided", key)
            self.assertEqual(cat["selector"]["matchLabels"],
                             {"olm.operatorframework.io/metadata.name": sources[key][1]}, key)
            # The raw text must quote the version so 5.7.1-style values never become floats.
            self.assertIn(f'version: "{heads[key]}"', r["manifests"]["30-clusterextension.yaml"], key)

    def test_sbr_static_bundle_rbac_is_reflected(self):
        r = self.results["sbr"]
        cr = self._manifest("sbr", "10-clusterrole.yaml")
        sa_manage = [x for x in cr["rules"] if x.get("resources") == ["serviceaccounts"] and "resourceNames" in x][0]
        self.assertIn("sbr-operator-sbr-agent", sa_manage["resourceNames"])
        self.assertTrue(any(x.get("nonResourceURLs") == ["/metrics"] for x in cr["rules"]))  # metrics-reader ClusterRole
        self.assertTrue(any(x.get("resources") == ["securitycontextconstraints"] and x.get("verbs") == ["use"]
                            for x in cr["rules"]))
        self.assertEqual(sum(1 for o in r["others"] if o["kind"] == "ClusterRole"), 13)

    def test_nhc_console_plugin_deployment_and_service_present(self):
        cr = self._manifest("nhc", "10-clusterrole.yaml")
        dep_manage = [x for x in cr["rules"] if x.get("resources") == ["deployments"] and "resourceNames" in x][0]
        self.assertIn("node-healthcheck-node-remediation-console-plugin", dep_manage["resourceNames"])
        svc_manage = [x for x in cr["rules"] if x.get("resources") == ["services"] and "resourceNames" in x][0]
        self.assertIn("node-healthcheck-node-remediation-console-plugin", svc_manage["resourceNames"])
        self.assertIn("node-healthcheck-controller-manager-service", svc_manage["resourceNames"])  # OLM v1 webhook Service

    # ------------------------------------------------------------------ wao (POC bundle)
    WAO_BUNDLE = os.path.join(HERE, "..", "..", "bundle")

    def _wao_csv(self) -> dict:
        return gen.load_yaml_or_json(os.path.join(self.WAO_BUNDLE, "manifests", "workload-availability-operator.clusterserviceversion.yaml"))

    def _wao_annotations(self) -> dict:
        return gen.load_yaml_or_json(os.path.join(self.WAO_BUNDLE, "metadata", "annotations.yaml"))["annotations"]

    def test_wao_yields_four_manifests_plus_kustomization(self):
        r = self.results["wao"]
        kinds = {n: self._manifest("wao", n)["kind"] for n in r["manifests"] if n != "kustomization.yaml"}
        self.assertEqual(kinds, {"00-serviceaccount.yaml": "ServiceAccount", "10-clusterrole.yaml": "ClusterRole",
                                 "20-clusterrolebinding.yaml": "ClusterRoleBinding", "30-clusterextension.yaml": "ClusterExtension"})
        self.assertEqual(self._manifest("wao", "kustomization.yaml")["resources"], sorted(kinds))
        self.assertEqual(self._manifest("wao", "00-serviceaccount.yaml")["metadata"]["name"], "wao-installer")
        # The POC bundle ships only the CSV and CRDs: no static Role/ClusterRole/Service/ConfigMap objects.
        self.assertEqual(r["others"], [])

    def test_wao_crd_rule_is_scoped_to_all_thirteen_bundle_crds(self):
        cr = self._manifest("wao", "10-clusterrole.yaml")
        bundle_crds = gen.load_bundle_crd_names(os.path.join(self.WAO_BUNDLE, "manifests"))
        self.assertEqual(len(bundle_crds), 13)
        crd_manage = [x for x in cr["rules"] if x.get("resources") == ["customresourcedefinitions"] and "resourceNames" in x]
        self.assertEqual(len(crd_manage), 1)
        self.assertEqual(crd_manage[0]["apiGroups"], ["apiextensions.k8s.io"])
        self.assertEqual(crd_manage[0]["verbs"], ["get", "update", "patch", "delete"])
        self.assertEqual(crd_manage[0]["resourceNames"], bundle_crds)
        self.assertEqual(len(crd_manage[0]["resourceNames"]), 13)
        # and the CSV owned list agrees with the bundle objects
        self.assertEqual(self.results["wao"]["info"]["owned_crds"], bundle_crds)

    def test_wao_finalizers_rule_is_scoped_to_workload_availability_operator(self):
        cr = self._manifest("wao", "10-clusterrole.yaml")
        fin = [x for x in cr["rules"] if x.get("resources") == ["clusterextensions/finalizers"]]
        self.assertEqual(len(fin), 1)
        self.assertEqual(fin[0], {"apiGroups": ["olm.operatorframework.io"], "resources": ["clusterextensions/finalizers"],
                                  "verbs": ["update"], "resourceNames": ["workload-availability-operator"]})
        self.assertEqual(self._manifest("wao", "30-clusterextension.yaml")["metadata"]["name"], "workload-availability-operator")

    def test_wao_clusterextension_matches_bundle_annotations_and_csv_version(self):
        ce = self._manifest("wao", "30-clusterextension.yaml")
        ann = self._wao_annotations()
        csv = self._wao_csv()
        cat = ce["spec"]["source"]["catalog"]
        self.assertEqual(cat["packageName"], ann["operators.operatorframework.io.bundle.package.v1"])
        self.assertEqual(cat["packageName"], "workload-availability-operator")
        self.assertEqual(cat["channels"], [ann["operators.operatorframework.io.bundle.channel.default.v1"]])
        self.assertEqual(cat["version"], str(csv["spec"]["version"]))
        self.assertIn(f'version: "{csv["spec"]["version"]}"', self.results["wao"]["manifests"]["30-clusterextension.yaml"])
        self.assertEqual(cat["upgradeConstraintPolicy"], "CatalogProvided")
        self.assertEqual(gen.WAO_CATALOG_NAME, "wao-poc")
        self.assertEqual(cat["selector"]["matchLabels"], {"olm.operatorframework.io/metadata.name": gen.WAO_CATALOG_NAME})
        self.assertEqual(ce["spec"]["namespace"], "openshift-workload-availability")
        self.assertEqual(ce["spec"]["serviceAccount"]["name"], "wao-installer")
        self.assertEqual(ce["spec"]["source"]["sourceType"], "Catalog")

    def test_wao_every_clusterpermission_verb_resource_pair_is_in_the_clusterrole(self):
        cr = self._manifest("wao", "10-clusterrole.yaml")
        strategy = self._wao_csv()["spec"]["install"]["spec"]
        self.assertTrue(strategy["clusterPermissions"])
        checked = 0
        for perm in strategy["clusterPermissions"]:
            for want in perm["rules"]:
                if want.get("nonResourceURLs"):
                    for url in want["nonResourceURLs"]:
                        for verb in want["verbs"]:
                            self.assertTrue(any(url in h.get("nonResourceURLs", []) and (verb in h["verbs"] or "*" in h["verbs"])
                                                for h in cr["rules"]), f"nonResourceURL {url} {verb}")
                            checked += 1
                    continue
                for group in want.get("apiGroups", []):
                    for resource in want["resources"]:
                        for verb in want["verbs"]:
                            self.assertTrue(any(
                                (group in h.get("apiGroups", []) or "*" in h.get("apiGroups", []))
                                and (resource in h.get("resources", []) or "*" in h.get("resources", []))
                                and (verb in h["verbs"] or "*" in h["verbs"])
                                and (not h.get("resourceNames") or set(want.get("resourceNames") or []) <= set(h["resourceNames"]))
                                for h in cr["rules"]), f"{group}/{resource} {verb} missing from wao ClusterRole")
                            checked += 1
        self.assertGreater(checked, 100)  # the POC CSV unions six operators' clusterPermissions

    def test_wao_rules_are_deduplicated_and_namespaces_rule_present(self):
        cr = self._manifest("wao", "10-clusterrole.yaml")
        keys = [gen.rule_key(x) for x in cr["rules"]]
        self.assertEqual(len(keys), len(set(keys)), "duplicate rules in wao ClusterRole")
        # the CSV repeats three clusterPermissions rules verbatim; they must be emitted once
        raw = self._wao_csv()["spec"]["install"]["spec"]["clusterPermissions"][0]["rules"]
        self.assertGreater(len(raw), len({gen.rule_key(gen.normalize_rule(x)) for x in raw}))
        self.assertTrue(any(x.get("apiGroups") == [""] and x.get("resources") == ["namespaces"]
                            and {"get", "list", "watch"} <= set(x["verbs"]) for x in cr["rules"]))
        self.assertFalse(self.results["wao"]["info"]["webhooks"])  # no webhookdefinitions, so no webhook rules

    def test_every_rule_group_has_a_source_comment(self):
        for key, r in self.results.items():
            text = r["manifests"]["10-clusterrole.yaml"]
            self.assertEqual(text.count("\n# --- "), len(r["groups"]), key)
            self.assertEqual(text.count("\n#     source: "), len(r["groups"]), key)

    def test_write_outputs_round_trips_through_yaml(self):
        with tempfile.TemporaryDirectory() as tmp:
            for r in self.results.values():
                for p in gen.write_outputs(r, tmp):
                    with open(p, encoding="utf-8") as fh:
                        docs = [d for d in yaml.safe_load_all(fh) if d]
                    self.assertEqual(len(docs), 1, p)


if __name__ == "__main__":
    unittest.main()
