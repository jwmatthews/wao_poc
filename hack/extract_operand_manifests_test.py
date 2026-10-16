# hack/extract_operand_manifests_test.py
import hashlib, json, pathlib, subprocess, sys, tempfile, unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
SCRIPT = HERE / "extract-operand-manifests.py"
CACHE = REPO / ".cache/bundles"
RELEASE_SET = REPO / "release-set.yaml"
# The rule OLM appends to each cluster-wide copy of a CSV's namespaced permissions (AllNamespaces install).
OLM_NAMESPACES_RULE = {"apiGroups": [""], "resources": ["namespaces"], "verbs": ["get", "list", "watch"]}


def run(out, crd_out, rbac_out, *extra):
    cmd = [sys.executable, str(SCRIPT), "--bundles", str(CACHE), "--release-set", str(RELEASE_SET),
           "--out", str(out), "--crd-out", str(crd_out), "--rbac-out", str(rbac_out), *extra]
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def load_all(directory):
    return {f.name: yaml.safe_load(f.read_text()) for f in sorted(pathlib.Path(directory).glob("*.yaml"))}


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


@unittest.skipUnless((CACHE / "nhc" / "fetch.json").exists(), "run `make bundles` first")
class ExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.tmp.name)
        cls.out, cls.crd_out, cls.rbac_out = root / "manifests", root / "crds", root / "union.yaml"
        run(cls.out, cls.crd_out, cls.rbac_out)
        cls.docs = {c: load_all(cls.out / c) for c in ("nhc", "snr", "sbr", "far", "mdr", "nmo")}
        cls.nhc, cls.snr, cls.sbr = cls.docs["nhc"], cls.docs["snr"], cls.docs["sbr"]
        cls.far, cls.mdr, cls.nmo = cls.docs["far"], cls.docs["mdr"], cls.docs["nmo"]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def kinds(self, docs, kind):
        return [d for d in docs.values() if d["kind"] == kind]

    def test_nhc_manager_and_validating_webhook(self):
        self.assertEqual([d["metadata"]["name"] for d in self.kinds(self.nhc, "Deployment")], ["node-healthcheck-controller-manager"])
        vw = self.kinds(self.nhc, "ValidatingWebhookConfiguration")
        self.assertEqual(len(vw), 1)
        self.assertEqual(vw[0]["metadata"]["name"], "node-healthcheck-validating-webhook-configuration")
        hook = vw[0]["webhooks"][0]
        self.assertEqual(hook["name"], "vnodehealthcheck.kb.io")
        self.assertEqual(hook["failurePolicy"], "Fail")
        self.assertEqual(hook["clientConfig"]["service"], {"name": "node-healthcheck-webhook-service", "namespace": "__WAO_NAMESPACE__",
                                                           "path": "/validate-remediation-medik8s-io-v1alpha1-nodehealthcheck", "port": 443})
        self.assertEqual(vw[0]["metadata"]["annotations"]["service.beta.openshift.io/inject-cabundle"], "true")

    def test_snr_webhooks_split_by_kind_and_keep_policies(self):
        vw = self.kinds(self.snr, "ValidatingWebhookConfiguration")[0]
        mw = self.kinds(self.snr, "MutatingWebhookConfiguration")[0]
        self.assertEqual({w["name"]: w["failurePolicy"] for w in vw["webhooks"]},
                         {"vselfnoderemediation.kb.io": "Ignore", "vselfnoderemediationconfig.kb.io": "Fail",
                          "vselfnoderemediationtemplate.kb.io": "Fail"})
        self.assertEqual([w["name"] for w in mw["webhooks"]], ["mselfnoderemediationtemplate.kb.io"])
        self.assertEqual(mw["metadata"]["name"], "self-node-remediation-mutating-webhook-configuration")

    def test_webhook_deployments_mount_service_ca_certificate(self):
        for docs, dep, secret in ((self.nhc, "node-healthcheck-controller-manager", "node-healthcheck-webhook-server-cert"),
                                  (self.snr, "self-node-remediation-controller-manager", "self-node-remediation-webhook-server-cert")):
            d = next(x for x in self.kinds(docs, "Deployment") if x["metadata"]["name"] == dep)
            vols = {v["name"]: v for v in d["spec"]["template"]["spec"]["volumes"]}
            self.assertEqual(vols["webhook-server-cert"]["secret"]["secretName"], secret)
            manager = next(c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "manager")
            mount = {m["name"]: m for m in manager["volumeMounts"]}["webhook-server-cert"]
            self.assertEqual(mount["mountPath"], "/tmp/k8s-webhook-server/serving-certs")
            self.assertTrue(mount["readOnly"])
            svc = next(s for s in self.kinds(docs, "Service") if s["metadata"]["name"].endswith("webhook-service"))
            self.assertEqual(svc["metadata"]["annotations"]["service.beta.openshift.io/serving-cert-secret-name"], secret)

    def test_sbr_has_no_webhooks_and_agent_binding_namespace_rewritten(self):
        self.assertEqual(self.kinds(self.sbr, "ValidatingWebhookConfiguration") + self.kinds(self.sbr, "MutatingWebhookConfiguration"), [])
        crb = next(x for x in self.kinds(self.sbr, "ClusterRoleBinding") if x["metadata"]["name"] == "sbr-operator-sbr-agent-rolebinding")
        self.assertEqual(crb["subjects"][0]["namespace"], "__WAO_NAMESPACE__")
        sa = next(x for x in self.kinds(self.sbr, "ServiceAccount") if x["metadata"]["name"] == "sbr-operator-sbr-agent")
        self.assertEqual(sa["metadata"]["namespace"], "__WAO_NAMESPACE__")

    def test_csv_permissions_become_rbac_objects(self):
        crb = next(x for x in self.kinds(self.snr, "ClusterRoleBinding") if x["metadata"]["name"] == "self-node-remediation-controller-manager")
        self.assertEqual(crb["subjects"], [{"kind": "ServiceAccount", "name": "self-node-remediation-controller-manager", "namespace": "__WAO_NAMESPACE__"}])
        role = next(x for x in self.kinds(self.snr, "Role") if x["metadata"]["name"] == "self-node-remediation-controller-manager")
        self.assertTrue(any("leases" in r["resources"] for r in role["rules"]))

    def csv(self, comp):
        f = next((CACHE / comp / "manifests").glob("*.clusterserviceversion.yaml"))
        return yaml.safe_load(f.read_text())

    def test_csv_namespaced_permissions_are_also_granted_cluster_wide(self):
        # OLM's OperatorGroup controller (ensureSingletonRBAC) copies every Role produced from CSV `permissions`
        # into a ClusterRole and ClusterRoleBinding when the OperatorGroup targets all namespaces, the only install
        # mode these CSVs support. WAO must grant the same effective RBAC.
        for comp, docs in self.docs.items():
            perms = self.csv(comp)["spec"]["install"]["spec"].get("permissions") or []
            self.assertTrue(perms, comp)
            cluster_roles = {d["metadata"]["name"]: d for d in self.kinds(docs, "ClusterRole")}
            bindings = self.kinds(docs, "ClusterRoleBinding")
            for p in perms:
                sa = p["serviceAccountName"]
                # the namespaced Role and RoleBinding stay, as OLM keeps them too
                self.assertTrue(any(r["rules"] == p["rules"] for r in self.kinds(docs, "Role")), f"{comp} Role for {sa}")
                self.assertTrue(any(b["subjects"] == [{"kind": "ServiceAccount", "name": sa, "namespace": "__WAO_NAMESPACE__"}]
                                    for b in self.kinds(docs, "RoleBinding")), f"{comp} RoleBinding for {sa}")
                copies = [b for b in bindings
                          if b["subjects"] == [{"kind": "ServiceAccount", "name": sa, "namespace": "__WAO_NAMESPACE__"}]
                          and b["roleRef"]["kind"] == "ClusterRole"
                          and b["roleRef"]["name"] in cluster_roles
                          and cluster_roles[b["roleRef"]["name"]]["rules"] == p["rules"] + [OLM_NAMESPACES_RULE]]
                self.assertEqual(len(copies), 1, f"{comp}: no cluster-wide copy of the CSV permissions for {sa}")

    def test_all_namespaces_cluster_roles_append_olm_namespaces_rule(self):
        # OLM appends get/list/watch on namespaces to every cluster-wide copy it makes of a CSV's `permissions`.
        # Without it NMO cannot sync its cache for the medik8s-leases Namespace and exits (live case WAO-INST-12).
        for comp, docs in self.docs.items():
            cluster_roles = {d["metadata"]["name"]: d for d in self.kinds(docs, "ClusterRole")}
            for p in self.csv(comp)["spec"]["install"]["spec"].get("permissions") or []:
                name = p["serviceAccountName"] + "-all-namespaces"
                self.assertIn(name, cluster_roles, comp)
                self.assertEqual(cluster_roles[name]["rules"], p["rules"] + [OLM_NAMESPACES_RULE], f"{comp} ClusterRole/{name}")

    def test_nmo_manager_can_list_and_watch_namespaces_cluster_wide(self):
        sa = "node-maintenance-operator-controller-manager"
        roles = {d["metadata"]["name"]: d for d in self.kinds(self.nmo, "ClusterRole")}
        granted = [roles[b["roleRef"]["name"]] for b in self.kinds(self.nmo, "ClusterRoleBinding")
                   if {"kind": "ServiceAccount", "name": sa, "namespace": "__WAO_NAMESPACE__"} in b["subjects"]
                   and b["roleRef"]["name"] in roles]
        self.assertTrue(any("" in r["apiGroups"] and "namespaces" in r["resources"] and {"list", "watch"} <= set(r["verbs"])
                            for role in granted for r in role["rules"]), "NMO manager lacks cluster-wide list/watch on namespaces")

    def test_far_manager_can_list_secrets_cluster_wide(self):
        sa = "fence-agents-remediation-controller-manager"
        roles = {d["metadata"]["name"]: d for d in self.kinds(self.far, "ClusterRole")}
        granted = [roles[b["roleRef"]["name"]] for b in self.kinds(self.far, "ClusterRoleBinding")
                   if {"kind": "ServiceAccount", "name": sa, "namespace": "__WAO_NAMESPACE__"} in b["subjects"]
                   and b["roleRef"]["name"] in roles]
        self.assertTrue(any("" in r["apiGroups"] and "secrets" in r["resources"] and {"list", "watch"} <= set(r["verbs"])
                            for role in granted for r in role["rules"]), "FAR manager lacks cluster-wide list/watch on secrets")

    def test_cluster_scoped_rbac_names_are_unique_across_components(self):
        seen = {}
        for comp, docs in self.docs.items():
            for kind in ("ClusterRole", "ClusterRoleBinding"):
                for d in self.kinds(docs, kind):
                    ident = (kind, d["metadata"]["name"])
                    self.assertNotIn(ident, seen, f"{ident} rendered by {seen.get(ident)} and {comp}")
                    seen[ident] = comp

    def test_images_keep_upstream_references(self):
        rs = yaml.safe_load(RELEASE_SET.read_text())
        text = "".join((self.out / "snr" / n).read_text() for n in self.snr)
        self.assertIn(rs["components"]["snr"]["images"]["RELATED_IMAGE_SNR_MANAGER"]["upstream"], text)
        text = "".join((self.out / "sbr" / n).read_text() for n in self.sbr)
        self.assertIn(rs["components"]["sbr"]["images"]["RELATED_IMAGE_SBR_AGENT"]["upstream"], text)

    def test_unknown_upstream_image_fails_extraction(self):
        rs = yaml.safe_load(RELEASE_SET.read_text())
        agent = rs["components"]["sbr"]["images"].pop("RELATED_IMAGE_SBR_AGENT")
        with tempfile.TemporaryDirectory() as d:
            alt = pathlib.Path(d) / "rs.yaml"
            alt.write_text(yaml.safe_dump(rs))
            r = subprocess.run([sys.executable, str(SCRIPT), "--bundles", str(CACHE), "--release-set", str(alt),
                                "--out", f"{d}/m", "--crd-out", f"{d}/c", "--rbac-out", f"{d}/u.yaml"], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(agent["upstream"], r.stdout + r.stderr)

    def test_far_and_nmo_webhooks(self):
        far_m = self.kinds(self.far, "MutatingWebhookConfiguration")[0]
        far_v = self.kinds(self.far, "ValidatingWebhookConfiguration")[0]
        self.assertEqual(sorted(w["name"] for w in far_m["webhooks"]), ["mfenceagentsremediation.kb.io", "mfenceagentsremediationtemplate.kb.io"])
        self.assertEqual(sorted(w["name"] for w in far_v["webhooks"]), ["vfenceagentsremediation.kb.io", "vfenceagentsremediationtemplate.kb.io"])
        self.assertTrue(all(w["failurePolicy"] == "Fail" for w in far_m["webhooks"] + far_v["webhooks"]))
        nmo_v = self.kinds(self.nmo, "ValidatingWebhookConfiguration")[0]
        self.assertEqual(nmo_v["metadata"]["name"], "node-maintenance-operator-validating-webhook-configuration")
        self.assertEqual([w["name"] for w in nmo_v["webhooks"]], ["vnodemaintenance.kb.io"])
        self.assertEqual(self.kinds(self.mdr, "ValidatingWebhookConfiguration") + self.kinds(self.mdr, "MutatingWebhookConfiguration"), [])

    def test_optional_webhook_fields_are_kept(self):
        nmo_v = self.kinds(self.nmo, "ValidatingWebhookConfiguration")[0]
        self.assertEqual(nmo_v["webhooks"][0]["timeoutSeconds"], 15)

    def test_union_role_holds_every_rule_wao_grants(self):
        # RBAC escalation prevention: WAO can only create a Role/ClusterRole whose rules it holds itself (D7).
        union = next(d for d in yaml.safe_load_all(self.rbac_out.read_text()) if d["kind"] == "ClusterRole")["rules"]
        held = {json.dumps(r, sort_keys=True) for r in union}
        for comp, docs in self.docs.items():
            for role in self.kinds(docs, "ClusterRole") + self.kinds(docs, "Role"):
                for r in role.get("rules") or []:
                    self.assertIn(json.dumps(r, sort_keys=True), held, f"{comp} {role['kind']}/{role['metadata']['name']}")

    def test_every_operand_pod_carries_its_component_label(self):
        keys = {"nhc": "nodeHealthCheck", "snr": "selfNodeRemediation", "sbr": "storageBasedRemediation",
                "far": "fenceAgentsRemediation", "mdr": "machineDeletionRemediation", "nmo": "nodeMaintenance"}
        for comp, docs in self.docs.items():
            for d in self.kinds(docs, "Deployment"):
                self.assertEqual(d["spec"]["template"]["metadata"]["labels"]["workloadavailability.medik8s.io/component"], keys[comp])

    def test_no_service_selects_another_components_pods(self):
        pods = {c: [d["spec"]["template"]["metadata"]["labels"] for d in self.kinds(docs, "Deployment")] for c, docs in self.docs.items()}
        for comp, docs in self.docs.items():
            for svc in self.kinds(docs, "Service"):
                sel = svc["spec"]["selector"]
                for other, labels in pods.items():
                    if other == comp:
                        continue
                    for l in labels:
                        self.assertFalse(all(l.get(k) == v for k, v in sel.items()), f"{comp} Service {svc['metadata']['name']} selects {other} pods")
                self.assertTrue(any(all(l.get(k) == v for k, v in sel.items()) for l in pods[comp]), f"{svc['metadata']['name']} selects none of its own pods")

    def test_mdr_metrics_service_was_narrowed(self):
        svc = next(s for s in self.kinds(self.mdr, "Service") if s["metadata"]["name"] == "machine-deletion-remediation-controller-manager-metrics-service")
        self.assertEqual(svc["spec"]["selector"], {"control-plane": "controller-manager", "workloadavailability.medik8s.io/component": "machineDeletionRemediation"})
        prov = json.loads((self.out / "provenance.json").read_text())
        self.assertTrue(any("selector narrowed" in m for m in prov["bundles"]["mdr"]["wao_modifications"]))
        nhc_svcs = [s["spec"]["selector"] for s in self.kinds(self.nhc, "Service")]
        self.assertTrue(all("workloadavailability.medik8s.io/component" not in s for s in nhc_svcs), "non-overlapping selectors stay verbatim")

    def test_crds_copied_and_union_role_written(self):
        self.assertEqual(len(list(self.crd_out.glob("*.yaml"))), 12)
        docs = list(yaml.safe_load_all(self.rbac_out.read_text()))
        role = next(d for d in docs if d["kind"] == "ClusterRole")
        self.assertEqual(role["metadata"]["name"], "operand-union-role")
        self.assertTrue(any(r.get("resourceNames") == ["privileged"] and "use" in r["verbs"] for r in role["rules"]))
        self.assertTrue(any("validatingwebhookconfigurations" in r.get("resources", []) for r in role["rules"]))

    def test_provenance_and_determinism(self):
        prov = json.loads((self.out / "provenance.json").read_text())
        self.assertEqual(set(prov["bundles"]), {"nhc", "snr", "sbr", "far", "mdr", "nmo"})
        self.assertTrue(prov["bundles"]["nhc"]["bundle"].startswith("quay.io/medik8s/node-healthcheck-operator-bundle@sha256:"))
        for comp in prov["bundles"].values():
            for f, h in comp["outputs"].items():
                self.assertEqual(h, sha(self.out / f))
        with tempfile.TemporaryDirectory() as second:
            root = pathlib.Path(second)
            run(root / "m", root / "c", root / "u.yaml")
            for comp in ("nhc", "snr", "sbr", "far", "mdr", "nmo"):
                for f in (self.out / comp).glob("*.yaml"):
                    self.assertEqual(f.read_text(), (root / "m" / comp / f.name).read_text())

    def test_check_mode_passes_on_committed_outputs(self):
        committed = REPO / "internal/operands/manifests"
        if not committed.exists():
            self.skipTest("committed outputs not generated yet")
        run(committed, REPO / "config/crd/bases", REPO / "config/rbac/operand_union_role.yaml", "--check")


if __name__ == "__main__":
    unittest.main()
