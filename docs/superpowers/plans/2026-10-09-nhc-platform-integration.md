# NHC OpenShift Platform Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enabled NHC on OpenShift gets working platform metrics (issue #3) and a working console backend (issue #4) through WAO's existing operand lifecycle.

**Architecture:** NHC's bundle in `release-set.yaml` becomes the digest-pinned OKD community bundle, so the console backend Deployment, Service and ServiceAccount flow through the existing extractor. The OCP metrics overlay (CA ConfigMap, metrics Service label and serving cert, manager TLS mount, Prometheus discovery RBAC) is applied by the extractor from verbatim upstream source files stored under `hack/platform/nhc/` with provenance. The controller gains a ConfigMap watch; everything else reuses the current apply, readiness, conflict and disable paths.

**Tech Stack:** Go 1.24 module with controller-runtime v0.21 and envtest (Ginkgo/Gomega); Python 3 with PyYAML 6.0.3 for `hack/` and `test/cluster/`; GNU Make; operator-sdk v1.42.3 and kustomize v5.6.0 under `bin/`; `oc` for the live harness.

**Spec:** [docs/superpowers/specs/2026-10-09-nhc-platform-integration-design.md](../specs/2026-10-09-nhc-platform-integration-design.md). Read it and [AGENTS.md](../../../AGENTS.md) first.

## Global Constraints

- Component images are consumed unchanged, pinned by digest in `release-set.yaml`. No public API field overrides an image. No component is forked or rebuilt.
- Every component defaults to `Disabled`; an all-Disabled install creates no NHC object.
- Never change a webhook `failurePolicy`. Never adopt an object WAO did not create; report the conflict.
- WAO never reads or writes `consoles.operator.openshift.io/cluster`, never touches `ConsolePlugin/node-remediation-console-plugin`, and does not report either in status (spec P7).
- Generated files (`internal/operands/manifests/`, `config/crd/bases/` component CRDs, `config/rbac/operand_union_role.yaml`, `bundle/`) are regenerated, never hand-edited. Files under `hack/platform/nhc/` are verbatim upstream copies, never edited.
- Before each commit: `make test` and `make test-offline` must pass; after packaging changes also `make operand-manifests-check` and `make bundle-check`. If `make test` fails on Go packages under ignored `evidence/` (known issue KI-6), run it from an isolated copy as shown in Task 1 Step 9 and say so in the commit or report.
- Small commits with a `wao:` prefix. Stage only this task's files: the workspace holds unrelated tracked changes (`README.md`, the bundle CSV, `config/manager/kustomization.yaml`, all carrying an image digest) and untracked files that must be preserved. Task 1 is the one task that deliberately includes those three files.
- Cluster work only against the kubeconfig the user confirmed in this session, passed explicitly on every command. Raw output goes under git-ignored `evidence/`; never capture Secret values; admission probes use server-side dry-run only; never create a real `NodeHealthCheck`, `StorageBasedRemediationConfig`, `NodeMaintenance` or remediation request.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. **Service-ca writes `data.service-ca.crt` into the CA ConfigMap with its own field manager after WAO created it.** WAO's next server-side apply (which forces ownership) must not strip that key. Pinned in Task 3 ("preserves the service-ca injected CA data").
2. **Upstream changes the OCP deployment patch so it no longer only adds a volume.** The extractor must refuse to silently absorb changed args or ports. Pinned in Task 2 (`test_nhc_platform_deployment_patch_drift_fails_extraction`).
3. **A `node-healthcheck-ca-bundle` ConfigMap already exists, created by someone else.** NHC must go `Degraded`, the object must stay untouched, and disable must not delete it. Pinned in Task 3 ("refuses to adopt a foreign CA ConfigMap").
4. **The Prometheus RoleBinding subject lives in `openshift-monitoring`.** The namespace rewrite must leave it alone or the platform Prometheus gets no grant. Pinned in Task 2 (`test_nhc_prometheus_discovery_rbac_keeps_external_subject`).
5. **The console pod joins a namespace where MDR's metrics Service selects `control-plane: controller-manager`.** The console pod carries no such label, so no cross-component Service may select it. Already pinned by the existing `test_no_service_selects_another_components_pods`; Task 1 re-runs it against the new bundle.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `release-set.yaml` | Pinned NHC OKD bundle and the new console image |
| `hack/platform/nhc/*.yaml`, `hack/platform/nhc/README.md` | Verbatim upstream OCP overlay files and their provenance |
| `hack/extract-operand-manifests.py` | Reads the bundle plus the platform files; emits manifests, union role, provenance |
| `hack/extract_operand_manifests_test.py` | Extractor behaviour, offline |
| `internal/images/images.go` | `RELATED_IMAGE_*` names, now eight |
| `internal/components/nhc.go` | NHC definition: two Deployments, two image bindings |
| `internal/controller/workloadavailabilityconfig_controller.go` | Adds the owned-ConfigMap watch |
| `cmd/main.go` | Scopes the ConfigMap cache to the install namespace |
| `config/manager/manager.yaml`, `config/manifests/bases/*.clusterserviceversion.yaml`, `bundle/` | Image env and relatedImages |
| `test/cluster/parity.py`, `parity_test.py` | Tolerates the TLS volume; explicit NHC platform contract |
| `test/cluster/lib.sh`, `05-enable-nhc.sh`, `15-disable-nmo-nhc.sh`, `18-uninstall.sh`, `run-all.sh`, `README.md` | Live checks and administrator enablement |
| `docs/operands.md`, `docs/design-brief.md`, `README.md`, `HANDOFF.md`, `docs/known-issues.md` | Documentation |

---

### Task 1: Console backend from the OKD community bundle, console image bound end to end

One commit, because the release-set change, the regenerated manifests, the Go image binding and the bundle must land together for `make test`, `make test-offline`, `make operand-manifests-check` and `make bundle-check` to all pass at the commit.

**Files:**
- Modify: `release-set.yaml`
- Modify: `hack/extract-operand-manifests.py` (COMPONENTS, `rbac()`)
- Modify: `internal/images/images.go`, `internal/components/nhc.go`
- Modify: `config/manager/manager.yaml`, `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml`
- Regenerate: `internal/operands/manifests/nhc/`, `internal/operands/manifests/provenance.json`, `config/rbac/operand_union_role.yaml`, `bundle/`
- Test: `hack/extract_operand_manifests_test.py`, `internal/images/images_test.go`, `internal/operands/render_test.go`

**Interfaces:**
- Produces: `COMPONENTS["nhc"]["automount_disabled"] = ["node-healthcheck-console-plugin"]`; `rbac(csv, comp, mods)` (new `comp` parameter); `images.NHCConsole = "RELATED_IMAGE_NHC_CONSOLE"` in `images.Required`; `components.NHC().Deployments == []string{"node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"}` (manager first: existing tests use `Deployments[0]` as the manager ServiceAccount name).
- New NHC manifests: `50-Deployment-node-healthcheck-node-remediation-console-plugin.yaml`, `40-Service-node-healthcheck-node-remediation-console-plugin.yaml`, `00-ServiceAccount-node-healthcheck-console-plugin.yaml`, `20-Role-node-healthcheck-console-plugin.yaml`, `21-RoleBinding-node-healthcheck-console-plugin.yaml`, `10-ClusterRole-node-healthcheck-console-plugin-all-namespaces.yaml`, `11-ClusterRoleBinding-node-healthcheck-console-plugin-all-namespaces.yaml`.

- [ ] **Step 1: Write the failing extractor test**

Append to the `ExtractionTest` class in `hack/extract_operand_manifests_test.py`:

```python
    def test_nhc_console_backend_from_okd_bundle(self):
        # Issue #4: the OKD community bundle is the k8s bundle plus the console backend.
        deps = {d["metadata"]["name"]: d for d in self.kinds(self.nhc, "Deployment")}
        self.assertIn("node-healthcheck-node-remediation-console-plugin", deps)
        d = deps["node-healthcheck-node-remediation-console-plugin"]
        pod = d["spec"]["template"]["spec"]
        c = pod["containers"][0]
        self.assertEqual(c["image"], "quay.io/medik8s/node-remediation-console:v0.12.0")
        self.assertEqual(c["ports"], [{"containerPort": 9443, "name": "nrc-server", "protocol": "TCP"}])
        self.assertEqual(c["volumeMounts"], [{"mountPath": "/var/serving-cert", "name": "nrc-plugin-cert", "readOnly": True}])
        self.assertEqual(pod["volumes"], [{"name": "nrc-plugin-cert", "secret": {"defaultMode": 420, "secretName": "nrc-plugin-cert"}}])
        self.assertEqual(pod["serviceAccountName"], "node-healthcheck-console-plugin")
        self.assertEqual(d["spec"]["template"]["metadata"]["labels"]["workloadavailability.medik8s.io/component"], "nodeHealthCheck")
        svc = next(s for s in self.kinds(self.nhc, "Service") if s["metadata"]["name"] == "node-healthcheck-node-remediation-console-plugin")
        self.assertEqual(svc["metadata"]["annotations"]["service.beta.openshift.io/serving-cert-secret-name"], "nrc-plugin-cert")
        self.assertEqual(svc["spec"]["ports"], [{"name": "9443-tcp", "port": 9443, "protocol": "TCP", "targetPort": "nrc-server"}])
        self.assertEqual(svc["spec"]["selector"], {"app.kubernetes.io/component": "node-remediation-console-plugin",
                                                   "app.kubernetes.io/name": "node-healthcheck-operator"})
        sa = next(x for x in self.kinds(self.nhc, "ServiceAccount") if x["metadata"]["name"] == "node-healthcheck-console-plugin")
        self.assertIs(sa["automountServiceAccountToken"], False, "upstream service_account.yaml disables token automount")
        role = next(x for x in self.kinds(self.nhc, "Role") if x["metadata"]["name"] == "node-healthcheck-console-plugin")
        self.assertEqual(role["rules"], [{"apiGroups": [""], "resourceNames": ["no-op-placeholder"], "resources": ["configmaps"], "verbs": ["get"]}])
        self.assertIn("node-healthcheck-console-plugin-all-namespaces", {x["metadata"]["name"] for x in self.kinds(self.nhc, "ClusterRole")})
        prov = json.loads((self.out / "provenance.json").read_text())
        self.assertTrue(prov["bundles"]["nhc"]["bundle"].startswith("quay.io/community-operator-pipeline-prod/node-healthcheck-operator@sha256:"))
        self.assertTrue(any("automountServiceAccountToken" in m for m in prov["bundles"]["nhc"]["wao_modifications"]))
```

In `test_provenance_and_determinism`, change the NHC bundle assertion to:

```python
        self.assertTrue(prov["bundles"]["nhc"]["bundle"].startswith("quay.io/community-operator-pipeline-prod/node-healthcheck-operator@sha256:"))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -k console_backend -v`
Expected: FAIL at `assertIn("node-healthcheck-node-remediation-console-plugin", deps)` (the cached k8s bundle has only the manager).

- [ ] **Step 3: Point the release set at the OKD bundle and add the console image**

In `release-set.yaml`, replace the `nhc:` block with:

```yaml
  nhc:
    version: v0.12.0
    source: https://github.com/medik8s/node-healthcheck-operator/tree/v0.12.0
    # The OKD community bundle that medik8s' release workflow builds from the same tag (community-operators-prod
    # pipeline). Verified identical to the published k8s bundle
    # quay.io/medik8s/node-healthcheck-operator-bundle@sha256:2a2ad916a9f827015474b4220b089ba61313112e697d45a50610186b620e1dba
    # except for the console backend Deployment, Service and ServiceAccount it adds (design brief D11).
    bundle: quay.io/community-operator-pipeline-prod/node-healthcheck-operator@sha256:e7684ebbcc543d8077fd218c7a1c9ce6c7ee622cce9d1806cd2672d792fcec72
    images:
      RELATED_IMAGE_NHC_MANAGER:
        upstream: quay.io/medik8s/node-healthcheck-operator:v0.12.0
        pinned: quay.io/medik8s/node-healthcheck-operator@sha256:5b048ad5d2b8578d2120989a5a822a041d65c985f9ac88d50b000427b32b5391
      RELATED_IMAGE_NHC_CONSOLE:
        upstream: quay.io/medik8s/node-remediation-console:v0.12.0
        pinned: quay.io/medik8s/node-remediation-console@sha256:f58fed1feef835bef8ddf9c7ab7edd987b87162866f68d76abd7be47ca737c2d
```

Then refetch: `make bundles`. Expected output includes `nhc: quay.io/community-operator-pipeline-prod/... -> 7 files`.

- [ ] **Step 4: Run the test again**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -k console_backend -v`
Expected: FAIL only at the `automountServiceAccountToken` assertion (`KeyError`). Everything else now comes from the bundle.

- [ ] **Step 5: Disable token automount for the console ServiceAccount in the extractor**

In `hack/extract-operand-manifests.py`, extend the NHC entry of `COMPONENTS`:

```python
    "nhc": {"key": "nodeHealthCheck", "prefix": "node-healthcheck", "webhook_service": "node-healthcheck-webhook-service",
            "webhook_deployment": "node-healthcheck-controller-manager",
            # OLM creates ServiceAccounts from CSV permissions, so the bundle cannot carry upstream's
            # config/optional/console-plugin/service_account.yaml setting; WAO restores it (design brief D11).
            "automount_disabled": ["node-healthcheck-console-plugin"]},
```

Change `rbac(csv, mods)` to `rbac(csv, comp, mods)` and replace the ServiceAccount loop at its end with:

```python
    for sa in sorted(sas):
        obj = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER}}
        if sa in comp.get("automount_disabled", []):
            obj["automountServiceAccountToken"] = False
            mods.append(f"ServiceAccount/{sa}: automountServiceAccountToken=false, as upstream's service_account.yaml sets it")
        out.append(obj)
```

Update the call in `main()`: `objects = rbac(csv, comp, mods) + other_objects(others, comp, mods) + deployments(csv, comp, mods) + webhooks(csv, comp, mods)`.

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v`
Expected: every test PASS except `test_check_mode_passes_on_committed_outputs` (`STALE OUTPUTS`, regenerated in Step 7).

- [ ] **Step 6: Write the failing Go tests**

In `internal/images/images_test.go`, extend the missing-variable loop in `TestFromEnvReportsEveryMissingVariable`:

```go
	for _, k := range []string{NHCConsole, SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager} {
```

Append to `internal/operands/render_test.go`:

```go
// Issue #4: the console backend is an NHC operand with its own pinned image (spec P2, P6).
func TestRenderNHCConsoleBackend(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	if want := []string{"node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"}; !reflect.DeepEqual(def.Deployments, want) {
		t.Fatalf("NHC deployments = %v, want %v", def.Deployments, want)
	}
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "node-healthcheck-node-remediation-console-plugin")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	if img := containers[0].(map[string]interface{})["image"]; img != testImages().Get(images.NHCConsole) {
		t.Fatalf("console image = %v, want the pinned %s", img, images.NHCConsole)
	}
	find(t, objs, "Service", "node-healthcheck-node-remediation-console-plugin")
	sa := find(t, objs, "ServiceAccount", "node-healthcheck-console-plugin")
	if v, ok, _ := unstructured.NestedBool(sa.Object, "automountServiceAccountToken"); !ok || v {
		t.Fatalf("console ServiceAccount automountServiceAccountToken = %v,%v, want false", v, ok)
	}
}
```

Run: `go test ./internal/images/ ./internal/operands/ 2>&1 | tail -20`
Expected: compile error `undefined: NHCConsole` in both packages.

- [ ] **Step 7: Add the image name and the NHC binding, regenerate the manifests**

`internal/images/images.go`:

```go
const (
	NHCManager = "RELATED_IMAGE_NHC_MANAGER"
	NHCConsole = "RELATED_IMAGE_NHC_CONSOLE"
	SNRManager = "RELATED_IMAGE_SNR_MANAGER"
	SBRManager = "RELATED_IMAGE_SBR_MANAGER"
	SBRAgent   = "RELATED_IMAGE_SBR_AGENT"
	FARManager = "RELATED_IMAGE_FAR_MANAGER"
	MDRManager = "RELATED_IMAGE_MDR_MANAGER"
	NMOManager = "RELATED_IMAGE_NMO_MANAGER"
)

// Required lists every image environment variable the operator needs at startup.
var Required = []string{NHCManager, NHCConsole, SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager}
```

`internal/components/nhc.go`:

```go
func NHC() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeHealthCheck, ShortName: "nhc", ManifestDir: "nhc",
		// The manager first: tests and parity use Deployments[0] as the manager ServiceAccount name.
		// The console backend is the OpenShift dynamic plugin server NHC registers a ConsolePlugin for (issue #4).
		Deployments: []string{"node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"},
		Images: []ImageBinding{
			{Env: images.NHCManager, Original: "quay.io/medik8s/node-healthcheck-operator:v0.12.0"},
			{Env: images.NHCConsole, Original: "quay.io/medik8s/node-remediation-console:v0.12.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-healthcheck-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "remediation.medik8s.io", Version: "v1alpha1", Kind: "NodeHealthCheck"}},
	}
}
```

Run: `make operand-manifests && make operand-manifests-check`
Expected: `wrote ... manifests, 12 CRDs, union role` then `outputs current`. `git status` shows the seven new files under `internal/operands/manifests/nhc/`, plus `provenance.json` and `config/rbac/operand_union_role.yaml` changes.

Run: `go test ./internal/images/ ./internal/operands/ ./internal/components/`
Expected: PASS, including `TestRenderReplacesEveryUpstreamImage` (no unbound `quay.io/medik8s/` reference remains) and `TestEveryDefinitionMatchesItsManifests`.

- [ ] **Step 8: Add the env and relatedImage, regenerate the bundle**

`config/manager/manager.yaml`, after the `RELATED_IMAGE_NHC_MANAGER` entry:

```yaml
        - name: RELATED_IMAGE_NHC_CONSOLE
          value: quay.io/medik8s/node-remediation-console@sha256:f58fed1feef835bef8ddf9c7ab7edd987b87162866f68d76abd7be47ca737c2d
```

`config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml`, after the `nhc-manager` relatedImage:

```yaml
  - image: quay.io/medik8s/node-remediation-console@sha256:f58fed1feef835bef8ddf9c7ab7edd987b87162866f68d76abd7be47ca737c2d
    name: nhc-console
```

The bundle must keep pointing at the WAO image the working tree already references (the one running on the cluster):

```bash
IMG=$(.venv/bin/python -c 'import yaml; i = yaml.safe_load(open("config/manager/kustomization.yaml"))["images"][0]; print(i["newName"] + "@" + i["digest"])')
echo "$IMG"   # image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@sha256:78859f4e...
make bundle IMG="$IMG" && make bundle-check
```

Expected: `operator-sdk bundle validate` passes and `bundle OK: workload-availability-operator.v0.1.0 owns 13 CRDs, 8 pinned operand images`. The CSV diff adds the `RELATED_IMAGE_NHC_CONSOLE` env and `nhc-console` relatedImage, and `createdAt` moves.

- [ ] **Step 9: Run the full offline suites**

Run: `make test-offline` then `make test`.

If `make test` fails with errors about packages under `evidence/` (KI-6), run it from an isolated copy that includes every tracked and untracked-but-not-ignored file, reusing the repo's tool binaries:

```bash
tmp=$(mktemp -d)
git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$tmp"
make -C "$tmp" test LOCALBIN="$PWD/bin"
diff -r "$tmp/config/crd/bases" config/crd/bases && diff "$tmp/config/rbac/role.yaml" config/rbac/role.yaml && echo "generated files unchanged"
rm -rf "$tmp"
```

Expected: `ok` for every package and `generated files unchanged` (this plan adds no kubebuilder markers or API fields). `make test-offline` PASS: the extractor check mode is current again, and `parity_test.py` compares the console Deployment too.

- [ ] **Step 10: Commit**

This commit intentionally includes the three previously dirty tracked files, because `make bundle` rewrites two of them and `README.md` quotes the same digest.

```bash
git add release-set.yaml hack/extract-operand-manifests.py hack/extract_operand_manifests_test.py \
        internal/images internal/components/nhc.go internal/operands config/rbac/operand_union_role.yaml \
        config/manager/manager.yaml config/manager/kustomization.yaml \
        config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml bundle README.md
git commit -m "wao: render the NHC console backend from the OKD community bundle

Select the digest-pinned OKD community bundle (the k8s bundle plus the
console backend), pin and bind the console image as RELATED_IMAGE_NHC_CONSOLE,
restore automountServiceAccountToken=false on the console ServiceAccount, list
the console Deployment in the NHC definition, regenerate manifests, union role
and bundle. The bundle keeps the WAO image digest the working tree referenced.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Apply the OCP metrics overlay from verbatim upstream files

**Files:**
- Create: `hack/platform/nhc/README.md`, `hack/platform/nhc/ca-configmap.yaml`, `hack/platform/nhc/prometheus-k8s-role.yaml`, `hack/platform/nhc/prometheus-k8s-rolebinding.yaml`, `hack/platform/nhc/auth_proxy_service_patch.yaml`, `hack/platform/nhc/deployment_patch.yaml`
- Modify: `hack/extract-operand-manifests.py`, `test/cluster/parity.py`
- Regenerate: `internal/operands/manifests/nhc/`, `provenance.json`, `config/rbac/operand_union_role.yaml`
- Test: `hack/extract_operand_manifests_test.py`, `test/cluster/parity_test.py`

**Interfaces:**
- Produces: `COMPONENTS["nhc"]["platform"]` dict with keys `upstream`, `commit`, `name_prefix`, `metrics_service`, `manager_deployment`, `files`; functions `load_platform(name, comp, platform_dir) -> {local: (upstream_path, sha256, parsed)}`, `platform_objects(comp, platform, mods) -> [objects]`, `apply_service_patch(obj, comp, platform, mods)`, `apply_deployment_patch(dep, comp, platform, mods)`; CLI flag `--platform DIR` (default `hack/platform`); provenance key `bundles.nhc.platform_sources = {"upstream", "commit", "files": {local: {"path", "sha256"}}}`; `parity.WAO_VOLUMES = {"webhook-server-cert", "tls-config"}`.
- New manifests: `30-ConfigMap-node-healthcheck-ca-bundle.yaml`, `20-Role-node-healthcheck-prometheus-k8s.yaml`, `21-RoleBinding-node-healthcheck-prometheus-k8s.yaml`; changed: the metrics Service and the manager Deployment.

- [ ] **Step 1: Copy the upstream files verbatim**

From the local upstream checkout, at the pinned commit. Do not retype them.

```bash
mkdir -p hack/platform/nhc
C=a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f
U=~/git/medik8s/node-healthcheck-operator
git -C "$U" show "${C}:config/optional/prometheus-ocp/ca-configmap.yaml"              > hack/platform/nhc/ca-configmap.yaml
git -C "$U" show "${C}:config/optional/prometheus-ocp/prometheus-k8s-role.yaml"       > hack/platform/nhc/prometheus-k8s-role.yaml
git -C "$U" show "${C}:config/optional/prometheus-ocp/prometheus-k8s-rolebinding.yaml" > hack/platform/nhc/prometheus-k8s-rolebinding.yaml
git -C "$U" show "${C}:config/manifests/ocp/auth_proxy_service_patch.yaml"            > hack/platform/nhc/auth_proxy_service_patch.yaml
git -C "$U" show "${C}:config/manifests/ocp/deployment_patch.yaml"                    > hack/platform/nhc/deployment_patch.yaml
shasum -a 256 hack/platform/nhc/*.yaml
```

Expected hashes:

```text
cec581e690ef884b514dac8a4a517d54636281cdfdd0909750ab124e075ba0b3  ca-configmap.yaml
342a03e70ef66710d87255240225915fcc1e9ec19639e52c09f7de1eeab2ff98  prometheus-k8s-role.yaml
466bf2ffbd165e9d11157a394e414c678d77d780d4886389c24a922f25800230  prometheus-k8s-rolebinding.yaml
dd82781424269e9c75bc21f612d22a1864e2e0af3a5e17d2e4ab6527b3e9faeb  auth_proxy_service_patch.yaml
bd746f994645bce1c42c420928af1de83a754da13345d2023950aaa4e188899f  deployment_patch.yaml
```

If the checkout is missing, fetch each file from `https://raw.githubusercontent.com/medik8s/node-healthcheck-operator/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/<path>` and verify the same hashes.

Write `hack/platform/nhc/README.md`:

```markdown
# NHC OpenShift packaging inputs

Verbatim copies of upstream Node Health Check source files that the OpenShift (`bundle-ocp`)
packaging applies and the published bundles do not carry. `hack/extract-operand-manifests.py`
reads them and records their sha256 in `internal/operands/manifests/provenance.json`
(`bundles.nhc.platform_sources`). Never edit these files; replace them from a new pinned
commit and update `NHC_PLATFORM["commit"]` in the extractor.

Repository: https://github.com/medik8s/node-healthcheck-operator
Commit: `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f` (tag v0.12.0, the pinned manager image)

| File | Upstream path | Applied as |
| --- | --- | --- |
| `ca-configmap.yaml` | `config/optional/prometheus-ocp/ca-configmap.yaml` | `ConfigMap/node-healthcheck-ca-bundle`; service-ca injects `service-ca.crt` |
| `prometheus-k8s-role.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-role.yaml` | `Role/node-healthcheck-prometheus-k8s` |
| `prometheus-k8s-rolebinding.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-rolebinding.yaml` | `RoleBinding/node-healthcheck-prometheus-k8s`, subject `openshift-monitoring/prometheus-k8s` kept |
| `auth_proxy_service_patch.yaml` | `config/manifests/ocp/auth_proxy_service_patch.yaml` | labels and annotations merged into the metrics Service |
| `deployment_patch.yaml` | `config/manifests/ocp/deployment_patch.yaml` | `tls-config` volume and mount added to the manager; args and ports must equal the bundle's |

Upstream renders these through kustomize with `namePrefix: node-healthcheck-` and namespace
`system`; the extractor applies the prefix and WAO's namespace placeholder. The overlay's
`kube-system` Role is deliberately not copied: WAO already grants the CSV's namespaced
permissions cluster-wide (design brief D7), which covers reading
`kube-system/extension-apiserver-authentication`.
```

- [ ] **Step 2: Write the failing extractor tests**

Append to `ExtractionTest`:

```python
    def test_nhc_metrics_platform_wiring(self):
        # Issue #3: what upstream's config/manifests/ocp overlay adds for platform Prometheus mTLS.
        svc = next(s for s in self.kinds(self.nhc, "Service") if s["metadata"]["name"] == "node-healthcheck-controller-manager-metrics-service")
        self.assertEqual(svc["metadata"]["labels"]["app.kubernetes.io/instance"], "metrics")
        self.assertEqual(svc["metadata"]["annotations"]["service.beta.openshift.io/serving-cert-secret-name"], "node-healthcheck-tls")
        self.assertNotIn("app.kubernetes.io/instance", svc["spec"]["selector"], "the label is on the Service, not the pods")
        d = next(x for x in self.kinds(self.nhc, "Deployment") if x["metadata"]["name"] == "node-healthcheck-controller-manager")
        pod = d["spec"]["template"]["spec"]
        vol = next(v for v in pod["volumes"] if v["name"] == "tls-config")
        self.assertEqual(vol, {"name": "tls-config", "secret": {"secretName": "node-healthcheck-tls"}}, "not optional: startup waits for issuance")
        manager = next(c for c in pod["containers"] if c["name"] == "manager")
        self.assertIn({"name": "tls-config", "mountPath": "/etc/tls/private", "readOnly": True}, manager["volumeMounts"])
        self.assertIn("webhook-server-cert", [m["name"] for m in manager["volumeMounts"]], "D1 webhook wiring still present")
        cm = next(x for x in self.kinds(self.nhc, "ConfigMap") if x["metadata"]["name"] == "node-healthcheck-ca-bundle")
        self.assertEqual(cm["metadata"]["annotations"], {"service.beta.openshift.io/inject-cabundle": "true"})
        self.assertEqual(cm["metadata"]["namespace"], "__WAO_NAMESPACE__")
        self.assertNotIn("data", cm, "service-ca owns the data; WAO applies none")

    def test_nhc_prometheus_discovery_rbac_keeps_external_subject(self):
        role = next(x for x in self.kinds(self.nhc, "Role") if x["metadata"]["name"] == "node-healthcheck-prometheus-k8s")
        self.assertTrue(any("endpointslices" in r["resources"] for r in role["rules"]))
        rb = next(x for x in self.kinds(self.nhc, "RoleBinding") if x["metadata"]["name"] == "node-healthcheck-prometheus-k8s")
        self.assertEqual(rb["roleRef"], {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "node-healthcheck-prometheus-k8s"})
        self.assertEqual(rb["subjects"], [{"kind": "ServiceAccount", "name": "prometheus-k8s", "namespace": "openshift-monitoring"}])

    def test_nhc_client_ca_read_is_covered_without_a_kube_system_role(self):
        for comp, docs in self.docs.items():
            for d in docs.values():
                self.assertNotEqual(d["metadata"].get("namespace"), "kube-system", f"{comp} renders into kube-system")
        cr = next(x for x in self.kinds(self.nhc, "ClusterRole") if x["metadata"]["name"] == "node-healthcheck-controller-manager-all-namespaces")
        self.assertTrue(any("" in r["apiGroups"] and "configmaps" in r["resources"] and {"get", "list", "watch"} <= set(r["verbs"])
                            for r in cr["rules"]), "NHC manager cannot read kube-system/extension-apiserver-authentication")

    def test_nhc_platform_sources_recorded(self):
        prov = json.loads((self.out / "provenance.json").read_text())
        src = prov["bundles"]["nhc"]["platform_sources"]
        self.assertEqual(src["upstream"], "https://github.com/medik8s/node-healthcheck-operator")
        self.assertEqual(src["commit"], "a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f")
        self.assertEqual(set(src["files"]), {"ca-configmap.yaml", "prometheus-k8s-role.yaml", "prometheus-k8s-rolebinding.yaml",
                                             "auth_proxy_service_patch.yaml", "deployment_patch.yaml"})
        for local, entry in src["files"].items():
            self.assertEqual(entry["sha256"], sha(REPO / "hack/platform/nhc" / local), local)
            self.assertTrue(entry["path"].startswith("config/"), local)
        for comp in ("snr", "sbr", "far", "mdr", "nmo"):
            self.assertNotIn("platform_sources", prov["bundles"][comp])

    def test_nhc_platform_deployment_patch_drift_fails_extraction(self):
        # If upstream's OCP deployment patch ever changes more than the volume and mount, review it; do not absorb it silently.
        with tempfile.TemporaryDirectory() as d:
            plat = pathlib.Path(d) / "platform" / "nhc"
            plat.mkdir(parents=True)
            for f in (REPO / "hack/platform/nhc").glob("*.yaml"):
                (plat / f.name).write_text(f.read_text())
            patch = yaml.safe_load((plat / "deployment_patch.yaml").read_text())
            patch["spec"]["template"]["spec"]["containers"][0]["args"].append("--new-flag")
            (plat / "deployment_patch.yaml").write_text(yaml.safe_dump(patch))
            r = subprocess.run([sys.executable, str(SCRIPT), "--bundles", str(CACHE), "--release-set", str(RELEASE_SET),
                                "--platform", str(pathlib.Path(d) / "platform"),
                                "--out", f"{d}/m", "--crd-out", f"{d}/c", "--rbac-out", f"{d}/u.yaml"], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("deployment patch", r.stdout + r.stderr)
```

Append to `ParityTest` in `test/cluster/parity_test.py`:

```python
    def test_nhc_manager_tls_volume_is_tolerated_like_the_webhook_volume(self):
        # Spec P3: the metrics serving-certificate volume is a documented WAO addition, not drift.
        self.assertEqual(parity.WAO_VOLUMES, {"webhook-server-cert", "tls-config"})
        images = parity.image_map(self.release_set, "nhc")
        d = next(x for x in parity.bundle_csv("nhc")["spec"]["install"]["spec"]["deployments"] if x["name"] == "node-healthcheck-controller-manager")
        self.assertEqual(parity.compare_deployment(d, self.rendered("nhc", d["name"])["spec"], images), 0)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -k nhc_ -v`
Expected: `test_nhc_metrics_platform_wiring`, `test_nhc_prometheus_discovery_rbac_keeps_external_subject` and `test_nhc_platform_sources_recorded` FAIL (`StopIteration` or `KeyError: 'platform_sources'`); the drift test FAILS because `--platform` is an unknown argument (exit 2 and no "deployment patch" in the output); `test_nhc_client_ca_read_is_covered_without_a_kube_system_role` PASSES already (it documents why no kube-system Role is needed).

Run: `.venv/bin/python -m unittest discover -s test/cluster -p 'parity_test.py' -k tls_volume -v`
Expected: FAIL with `AttributeError: module 'parity' has no attribute 'WAO_VOLUMES'`.

- [ ] **Step 4: Implement the platform step in the extractor**

In `hack/extract-operand-manifests.py` add after `WAO_OWN_RULES`:

```python
# Upstream OpenShift packaging inputs the published bundles do not carry (design brief D11). Verbatim copies
# live under hack/platform/<component>/; see the README there. Only NHC has them at these releases.
PLATFORM_DIR_DEFAULT = pathlib.Path(__file__).resolve().parent / "platform"
NHC_PLATFORM = {
    "upstream": "https://github.com/medik8s/node-healthcheck-operator",
    "commit": "a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f",
    "name_prefix": "node-healthcheck-",   # kustomize namePrefix of upstream's config/patches/common
    "metrics_service": "node-healthcheck-controller-manager-metrics-service",
    "manager_deployment": "node-healthcheck-controller-manager",
    "files": {
        "ca-configmap.yaml": "config/optional/prometheus-ocp/ca-configmap.yaml",
        "prometheus-k8s-role.yaml": "config/optional/prometheus-ocp/prometheus-k8s-role.yaml",
        "prometheus-k8s-rolebinding.yaml": "config/optional/prometheus-ocp/prometheus-k8s-rolebinding.yaml",
        "auth_proxy_service_patch.yaml": "config/manifests/ocp/auth_proxy_service_patch.yaml",
        "deployment_patch.yaml": "config/manifests/ocp/deployment_patch.yaml",
    },
}
```

Add `"platform": NHC_PLATFORM` to the `nhc` entry of `COMPONENTS` (NHC_PLATFORM must be defined above COMPONENTS; move the block if needed).

Add these functions after `rewrite_subjects`:

```python
def load_platform(name, comp, platform_dir):
    """Verbatim upstream OpenShift packaging files: {local name: (upstream path, sha256, parsed object)}."""
    plat = comp.get("platform")
    if not plat:
        return {}
    out = {}
    for local, upstream in plat["files"].items():
        raw = (pathlib.Path(platform_dir) / name / local).read_bytes()
        out[local] = (upstream, sha256_bytes(raw), yaml.safe_load(raw))
    return out


def platform_objects(comp, platform, mods):
    """Objects the upstream OpenShift overlay adds and the bundle lacks: CA ConfigMap and Prometheus discovery RBAC."""
    out = []
    prefix = comp["platform"]["name_prefix"]
    for local in ("ca-configmap.yaml", "prometheus-k8s-role.yaml", "prometheus-k8s-rolebinding.yaml"):
        upstream, _, obj = platform[local]
        obj = clean(obj)
        obj["metadata"]["name"] = prefix + obj["metadata"]["name"]
        obj["metadata"]["namespace"] = NAMESPACE_PLACEHOLDER  # upstream `system` -> install namespace
        if obj["kind"] == "RoleBinding":
            obj["roleRef"]["name"] = prefix + obj["roleRef"]["name"]
            # The subject (openshift-monitoring/prometheus-k8s) is the platform's ServiceAccount; keep it verbatim.
        if obj["kind"] == "ConfigMap":
            obj.pop("data", None)  # service-ca injects service-ca.crt and owns it; WAO applies no data
        mods.append(f"{obj['kind']}/{obj['metadata']['name']}: added from upstream OpenShift packaging {upstream}")
        out.append(obj)
    return out


def apply_service_patch(obj, comp, platform, mods):
    """Merge the OCP metrics Service patch (instance label, serving-cert annotation) into the bundle's Service."""
    upstream, _, patch = platform["auth_proxy_service_patch.yaml"]
    if comp["platform"]["name_prefix"] + patch["metadata"]["name"] != comp["platform"]["metrics_service"]:
        raise SystemExit(f"{upstream} targets {patch['metadata']['name']}, not the metrics Service")
    obj["metadata"].setdefault("labels", {}).update(patch["metadata"].get("labels") or {})
    obj["metadata"].setdefault("annotations", {}).update(patch["metadata"].get("annotations") or {})
    mods.append(f"Service/{obj['metadata']['name']}: merged labels and annotations from upstream OpenShift packaging {upstream}")


def apply_deployment_patch(dep, comp, platform, mods):
    """Add the OCP deployment patch's metrics serving-certificate volume and mount to the manager.
    The patch repeats args and ports; they must equal the bundle's, otherwise the patch changed and needs review."""
    upstream, _, patch = platform["deployment_patch.yaml"]
    pod = dep["spec"]["template"]["spec"]
    manager = next(c for c in pod["containers"] if c["name"] == "manager")
    pc = next(c for c in patch["spec"]["template"]["spec"]["containers"] if c["name"] == "manager")
    if pc.get("args") != manager.get("args") or pc.get("ports") != manager.get("ports"):
        raise SystemExit(f"{dep['metadata']['name']}: upstream OpenShift deployment patch ({upstream}) changes args or ports; review it")
    manager.setdefault("volumeMounts", []).extend(copy.deepcopy(pc["volumeMounts"]))
    pod.setdefault("volumes", []).extend(copy.deepcopy(patch["spec"]["template"]["spec"]["volumes"]))
    names = ", ".join(v["name"] for v in patch["spec"]["template"]["spec"]["volumes"])
    mods.append(f"Deployment/{dep['metadata']['name']}: added metrics serving-certificate volume {names} from upstream OpenShift packaging {upstream}")
```

Change `deployments(csv, comp, mods)` to `deployments(csv, comp, platform, mods)` and, inside the loop after the webhook block, add:

```python
        if platform and d["name"] == comp["platform"]["manager_deployment"]:
            apply_deployment_patch(dep, comp, platform, mods)
```

Change `other_objects(others, comp, mods)` to `other_objects(others, comp, platform, mods)` and, inside the loop after the webhook Service block, add:

```python
        if platform and obj["kind"] == "Service" and obj["metadata"]["name"] == comp["platform"]["metrics_service"]:
            apply_service_patch(obj, comp, platform, mods)
```

In `main()` add the argument:

```python
    ap.add_argument("--platform", default=str(PLATFORM_DIR_DEFAULT), help="hack/platform: verbatim upstream OpenShift packaging inputs")
```

and change the component loop to:

```python
        platform = load_platform(name, comp, args.platform)
        mods = []
        objects = (rbac(csv, comp, mods) + other_objects(others, comp, platform, mods) + deployments(csv, comp, platform, mods)
                   + webhooks(csv, comp, mods) + (platform_objects(comp, platform, mods) if platform else []))
        rendered[name] = (objects, mods)
        meta[name] = (bundle_ref, csv["metadata"]["name"], inputs, crds, platform)
```

and the provenance block to:

```python
    for name, (objects, mods) in rendered.items():
        comp = COMPONENTS[name]
        files = {filename(o): dump(o) for o in objects}
        if len(files) != len(objects):
            raise SystemExit(f"{name}: duplicate output filenames")
        check_images(name, files, release_set)
        problems += write_tree(pathlib.Path(args.out) / name, files, args.check)
        bundle_ref, csv_name, inputs, crds, platform = meta[name]
        entry = {
            "bundle": bundle_ref, "csv": csv_name, "inputs": inputs,
            "outputs": {f"{name}/{fn}": sha256_bytes(text.encode()) for fn, text in sorted(files.items())},
            "crds": [c for c, _ in crds], "wao_modifications": sorted(set(mods)),
        }
        if platform:
            entry["platform_sources"] = {"upstream": comp["platform"]["upstream"], "commit": comp["platform"]["commit"],
                                         "files": {local: {"path": p, "sha256": h} for local, (p, h, _) in sorted(platform.items())}}
        provenance["bundles"][name] = entry
```

Add to the module docstring: "NHC also receives the upstream OpenShift packaging additions kept verbatim under hack/platform/nhc (D11)."

In `test/cluster/parity.py` replace `WAO_VOLUME = "webhook-server-cert"` with:

```python
# Volumes WAO adds to upstream Deployments: the service-ca webhook certificate (D1) and NHC's metrics serving
# certificate from the upstream OpenShift overlay (D11). Everything else in a pod spec must match the bundle.
WAO_VOLUMES = {"webhook-server-cert", "tls-config"}
```

and in `normalize_deployment` use `m["name"] not in WAO_VOLUMES` and `v["name"] not in WAO_VOLUMES`. Update the docstring line "Tolerated differences: ..." to name both volumes.

- [ ] **Step 5: Run the extractor suite and regenerate**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v`
Expected: all PASS except `test_check_mode_passes_on_committed_outputs`. Then:

```bash
make operand-manifests && make operand-manifests-check
```

Expected: `outputs current`; `git status` shows the three new NHC manifests, the changed metrics Service and manager Deployment, `provenance.json` and the union role (new `endpointslices` rule).

- [ ] **Step 6: Run every suite**

Run: `make test-offline` and `make test` (isolated copy if KI-6 bites). Also `make bundle-check` (unchanged bundle, still valid).
Expected: all PASS, including the parity tolerance test and `test_extracted_deployments_match_bundle` for the NHC manager.

- [ ] **Step 7: Commit**

```bash
git add hack/platform/nhc hack/extract-operand-manifests.py hack/extract_operand_manifests_test.py \
        test/cluster/parity.py test/cluster/parity_test.py internal/operands/manifests config/rbac/operand_union_role.yaml
git commit -m "wao: apply the NHC OpenShift metrics overlay from pinned upstream files

CA ConfigMap, metrics Service label and serving cert, manager TLS mount and
Prometheus discovery RBAC come verbatim from NHC a49ec14 config/manifests/ocp
and config/optional/prometheus-ocp, recorded in provenance. parity.py
tolerates the tls-config volume like the webhook certificate volume.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Controller: ConfigMap watch, namespace-scoped cache, envtest coverage

**Files:**
- Modify: `internal/controller/workloadavailabilityconfig_controller.go` (`SetupWithManager`)
- Modify: `cmd/main.go` (cache options)
- Test: `internal/controller/workloadavailabilityconfig_controller_test.go`

**Interfaces:**
- Consumes: `images.NHCConsole` (Task 1); rendered NHC manifests with the console Deployment and `ConfigMap/node-healthcheck-ca-bundle` (Tasks 1 and 2).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Extend the enable and disable tests and add the three ConfigMap tests**

In `"installs the NHC operand when enabled"`, change `g.Expect(c.Deployments).To(HaveLen(1))` to `HaveLen(2)` and append before the ClusterRole assertions:

```go
		console := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, console)).To(Succeed())
		Expect(console.Spec.Template.Spec.Containers[0].Image).To(Equal(testImages().Get(images.NHCConsole)))
		Expect(console.Labels[operands.LabelComponent]).To(Equal(v1alpha1.ComponentKeyNodeHealthCheck))
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		Expect(cm.Annotations).To(HaveKeyWithValue("service.beta.openshift.io/inject-cabundle", "true"))
		Expect(cm.Labels[operands.LabelManagedBy]).To(Equal(operands.ManagedByValue))
		Expect(cm.OwnerReferences).To(HaveLen(1))
		Expect(cm.Data).To(BeEmpty())
		consoleSA := &corev1.ServiceAccount{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-console-plugin"}, consoleSA)).To(Succeed())
		Expect(consoleSA.AutomountServiceAccountToken).To(Equal(ptr.To(false)))
```

Add two new `It` blocks right after it:

```go
	It("preserves the service-ca injected CA data across reconciles", func() {
		// service-ca writes service-ca.crt with its own field manager. WAO applies no data and forces ownership
		// of what it does apply, so the injected key must survive the next apply (spec P9).
		injected := &corev1.ConfigMap{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
			ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-ca-bundle", Namespace: ns},
			Data:       map[string]string{"service-ca.crt": "-----BEGIN CERTIFICATE-----\nenvtest\n-----END CERTIFICATE-----\n"}}
		Expect(k8sClient.Patch(ctx, injected, client.Apply, client.FieldOwner("service-ca-operator"))).To(Succeed())
		// Deleting an owned Deployment makes WAO re-apply every NHC object, the ConfigMap included.
		Expect(k8sClient.Delete(ctx, &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-node-remediation-console-plugin", Namespace: ns}})).To(Succeed())
		Eventually(func() error {
			return k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, &appsv1.Deployment{})
		}).Should(Succeed())
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		Expect(cm.Data).To(HaveKey("service-ca.crt"))
		Expect(cm.Annotations).To(HaveKeyWithValue("service.beta.openshift.io/inject-cabundle", "true"))
	})

	It("recreates the CA ConfigMap when it is deleted", func() {
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		uid := cm.UID
		Expect(k8sClient.Delete(ctx, cm)).To(Succeed())
		Eventually(func(g Gomega) {
			fresh := &corev1.ConfigMap{}
			g.Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, fresh)).To(Succeed())
			g.Expect(fresh.UID).NotTo(Equal(uid))
		}).Should(Succeed())
	})
```

In `"removes the NHC operand and reports admission unavailable when disabled"`, append:

```go
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, &corev1.ConfigMap{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-console-plugin"}, &corev1.ServiceAccount{}))).To(BeTrue())
```

Add after that `It`:

```go
	It("refuses to adopt a foreign CA ConfigMap", func() {
		foreign := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-ca-bundle", Namespace: ns}, Data: map[string]string{"service-ca.crt": "foreign"}}
		Expect(k8sClient.Create(ctx, foreign)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDegraded))
			g.Expect(c.Message).To(ContainSubstring("ConfigMap " + ns + "/node-healthcheck-ca-bundle"))
			g.Expect(c.Message).To(ContainSubstring("not managed by"))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed())
		Expect(foreign.Data).To(HaveKeyWithValue("service-ca.crt", "foreign"))
		Expect(foreign.Labels).NotTo(HaveKey(operands.LabelManagedBy))
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed(), "WAO must not delete a foreign object on disable")
		Expect(k8sClient.Delete(ctx, foreign)).To(Succeed()) // test cleanup, not WAO behavior
	})
```

- [ ] **Step 2: Run the controller suite to verify the new test fails**

Run: `KUBEBUILDER_ASSETS="$(bin/setup-envtest use 1.33.0 --bin-dir bin -p path)" go test ./internal/controller/ -ginkgo.v 2>&1 | tail -40`
Expected: `"recreates the CA ConfigMap when it is deleted"` FAILS (timed out, the UID never changes: nothing watches ConfigMaps). The enable, preserve, disable and foreign-ConfigMap specs PASS already, because the existing apply, conflict and delete paths are generic. State that in the commit message.

- [ ] **Step 3: Add the watch and scope the cache**

`internal/controller/workloadavailabilityconfig_controller.go`, in `SetupWithManager`, after `Owns(&corev1.Service{})`:

```go
		Owns(&corev1.ConfigMap{}). // the NHC CA ConfigMap: recreate on deletion, repair drift (spec P9)
```

`cmd/main.go`, in the `cache.Options` map:

```go
			&corev1.ConfigMap{}:  {Namespaces: map[string]cache.Config{operatorNamespace: {}}},
```

and extend the comment above it: "Namespaced operand kinds (Deployments, DaemonSets, Services, ConfigMaps) are cached only in the install namespace."

- [ ] **Step 4: Run the suites**

Run: `make test` (isolated copy if KI-6 bites) and `make test-offline`.
Expected: all PASS, including the recreate spec.

- [ ] **Step 5: Commit**

```bash
git add internal/controller/workloadavailabilityconfig_controller.go internal/controller/workloadavailabilityconfig_controller_test.go cmd/main.go
git commit -m "wao: watch the NHC CA ConfigMap and cover console and metrics operands in envtest

The deleted ConfigMap is recreated through an Owns watch; the injected
service-ca.crt key survives WAO's apply; a foreign ConfigMap is refused.
Enable, preserve and foreign tests passed before the change: the apply and
conflict paths are generic. Only the recreate test needed the watch.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Parity: explicit NHC platform contract

**Files:**
- Modify: `test/cluster/parity.py`
- Test: `test/cluster/parity_test.py`

**Interfaces:**
- Consumes: `parity.WAO_VOLUMES` (Task 2).
- Produces: `parity.check_platform_contract(component, get) -> int` where `get(kind, name)` returns a live object dict and the return value is the number of failed checks; `parity.NHC_PLATFORM_CONTRACT` and `parity.PLATFORM_CONTRACTS` data.

- [ ] **Step 1: Write the failing tests**

Append to `ParityTest` in `test/cluster/parity_test.py`:

```python
    def rendered_object(self, component, kind, name):
        f = next((REPO / "internal/operands/manifests" / component).glob(f"*-{kind}-{name}.yaml"))
        return yaml.safe_load(f.read_text())

    def test_nhc_platform_contract_passes_on_rendered_manifests(self):
        get = lambda kind, name: self.rendered_object("nhc", kind, name)
        self.assertEqual(parity.check_platform_contract("nhc", get), 0)
        self.assertEqual(parity.check_platform_contract("snr", get), 0, "only NHC has a platform contract")

    def test_nhc_platform_contract_detects_missing_supplements(self):
        # A bundle without the overlay on both sides must fail, not match (handoff requirement).
        def get(kind, name):
            o = copy.deepcopy(self.rendered_object("nhc", kind, name))
            if kind == "Service" and name == "node-healthcheck-controller-manager-metrics-service":
                o["metadata"]["labels"].pop("app.kubernetes.io/instance")
            if kind == "ConfigMap":
                o["metadata"]["annotations"] = {}
            if kind == "Deployment":
                for c in o["spec"]["template"]["spec"]["containers"]:
                    c["volumeMounts"] = [m for m in c.get("volumeMounts") or [] if m["name"] != "tls-config"]
            return o
        self.assertEqual(parity.check_platform_contract("nhc", get), 3)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m unittest discover -s test/cluster -p 'parity_test.py' -k platform_contract -v`
Expected: both FAIL with `AttributeError: module 'parity' has no attribute 'check_platform_contract'`.

- [ ] **Step 3: Implement**

Add to `test/cluster/parity.py` after `compare_binding`:

```python
# NHC-only OpenShift platform contract (design brief D11). The bundle on both sides of the comparison lacks these
# additions, so they are asserted explicitly: a missing supplement must fail, not match.
NHC_PLATFORM_CONTRACT = [
    ("Service", "node-healthcheck-controller-manager-metrics-service",
     lambda o: {"labels.instance": (o["metadata"].get("labels") or {}).get("app.kubernetes.io/instance"),
                "serving-cert": (o["metadata"].get("annotations") or {}).get("service.beta.openshift.io/serving-cert-secret-name")},
     {"labels.instance": "metrics", "serving-cert": "node-healthcheck-tls"}),
    ("ConfigMap", "node-healthcheck-ca-bundle",
     lambda o: {"inject-cabundle": (o["metadata"].get("annotations") or {}).get("service.beta.openshift.io/inject-cabundle")},
     {"inject-cabundle": "true"}),
    ("Deployment", "node-healthcheck-controller-manager",
     lambda o: {"manager-mounts": sorted((m["name"], m["mountPath"], bool(m.get("readOnly")))
                                         for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "manager"
                                         for m in c.get("volumeMounts") or [] if m["name"] == "tls-config"),
                "volumes": sorted((v["name"], (v.get("secret") or {}).get("secretName"))
                                  for v in o["spec"]["template"]["spec"].get("volumes") or [] if v["name"] == "tls-config")},
     {"manager-mounts": [["tls-config", "/etc/tls/private", True]], "volumes": [["tls-config", "node-healthcheck-tls"]]}),
    ("Service", "node-healthcheck-node-remediation-console-plugin",
     lambda o: {"serving-cert": (o["metadata"].get("annotations") or {}).get("service.beta.openshift.io/serving-cert-secret-name"),
                "port": o["spec"]["ports"][0]["port"]},
     {"serving-cert": "nrc-plugin-cert", "port": 9443}),
]
PLATFORM_CONTRACTS = {"nhc": NHC_PLATFORM_CONTRACT}


def check_platform_contract(component, get):
    """get(kind, name) -> live object. Returns the number of failed checks (0 when the component has no contract)."""
    failures = 0
    for kind, name, project_fn, want in PLATFORM_CONTRACTS.get(component, []):
        got = json.loads(json.dumps(project_fn(get(kind, name))))  # tuples -> lists, like the JSON diff below
        failures += diff(f"platform {kind}/{name}", want, got)
    return failures
```

In `main()`, before `sys.exit`:

```python
    failures += check_platform_contract(a.component, lambda kind, name: kubectl_json("get", kind, name, "-n", a.namespace))
```

Add to the module docstring: "For NHC, the OpenShift platform contract (metrics Service label and serving cert, CA ConfigMap, manager TLS mount, console Service) is asserted explicitly."

- [ ] **Step 4: Run the tests**

Run: `make test-offline`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add test/cluster/parity.py test/cluster/parity_test.py
git commit -m "wao: parity asserts the NHC OpenShift platform contract

Missing OpenShift supplements now fail parity instead of matching an
equally bare bundle.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Live-cluster harness: metrics and console checks, administrator enablement

**Files:**
- Modify: `test/cluster/lib.sh`, `test/cluster/05-enable-nhc.sh`, `test/cluster/15-disable-nmo-nhc.sh`, `test/cluster/18-uninstall.sh`, `test/cluster/run-all.sh` (RUN.md text), `test/cluster/README.md`

**Interfaces:**
- Produces in `lib.sh`: `prom_query EXPR`, `prom_all_values EXPR VALUE`, `sm_selects_service`, `console_plugins`, `console_plugin_enabled NAME`, `enable_console_plugin LABEL NAME`, `disable_console_plugin LABEL NAME`, `trusted_fetch LABEL URL`.
- The only offline check for shell is `bash -n` (part of `make test-offline`). Live behaviour is verified in Task 7.

- [ ] **Step 1: Add the helpers to `lib.sh`**

Append to the predicates section of `test/cluster/lib.sh`:

```bash
# ---- OpenShift platform helpers (design brief D11) -------------------------------------------

# prom_query EXPR : instant query against the platform Prometheus from inside its pod (read-only; the
# upstream NHC readme documents the same path). Prints the JSON result array.
prom_query() {
  k -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
    curl -sG --data-urlencode "query=$1" http://localhost:9090/api/v1/query |
    python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["data"]["result"]))'
}

# prom_all_values EXPR VALUE : every series of EXPR has VALUE, and there is at least one series.
prom_all_values() {
  local out; out=$(prom_query "$1") || return 1
  python3 -c 'import json, sys; r = json.loads(sys.argv[1]); sys.exit(0 if r and all(x["value"][1] == sys.argv[2] for x in r) else 1)' "$out" "$2"
}

# sm_selects_service : the NHC ServiceMonitor's matchLabels are all present on the metrics Service.
sm_selects_service() {
  local sel labels
  sel=$(k get servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS" -o jsonpath='{.spec.selector.matchLabels}') || return 1
  labels=$(k get service node-healthcheck-controller-manager-metrics-service -n "$NS" -o jsonpath='{.metadata.labels}') || return 1
  python3 -c 'import json, sys; s, l = json.loads(sys.argv[1]), json.loads(sys.argv[2]); sys.exit(0 if s and all(l.get(k) == v for k, v in s.items()) else 1)' "$sel" "$labels"
}

# console_plugins : the console's enabled plugin list as a JSON array ("[]" when unset). Never modified by WAO.
console_plugins() {
  local p; p=$(k get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}') || return 1
  printf '%s' "${p:-[]}"
}

# console_plugin_enabled NAME
console_plugin_enabled() {
  local p; p=$(console_plugins) || return 1
  python3 -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1]) else 1)' "$p" "$1"
}

# enable_console_plugin LABEL NAME : the administrator step. Appends NAME, preserving existing entries.
enable_console_plugin() {
  console_plugin_enabled "$2" && return 0
  if [ "$(console_plugins)" = "[]" ]; then
    record "$1" patch consoles.operator.openshift.io cluster --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins\",\"value\":[\"$2\"]}]" >/dev/null
  else
    record "$1" patch consoles.operator.openshift.io cluster --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"$2\"}]" >/dev/null
  fi
}

# disable_console_plugin LABEL NAME : remove NAME from spec.plugins, preserving the other entries.
disable_console_plugin() {
  local p idx
  p=$(console_plugins) || return 1
  idx=$(python3 -c 'import json, sys; l = json.loads(sys.argv[1]); print(l.index(sys.argv[2]) if sys.argv[2] in l else -1)' "$p" "$2")
  [ "$idx" -ge 0 ] || return 0
  record "$1" patch consoles.operator.openshift.io cluster --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/plugins/$idx\"}]" >/dev/null
}

# trusted_fetch LABEL URL : fetch URL from a short-lived pod in $NS, verifying TLS against the service CA that
# OpenShift publishes in every namespace (ConfigMap openshift-service-ca.crt). Prints the body. No -k anywhere.
trusted_fetch() {
  local pod="wao-fetch-$1" rc=0
  k delete pod "$pod" -n "$NS" --ignore-not-found >/dev/null
  k apply -n "$NS" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels: {wao-test: fetch}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: curl
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["curl", "-sS", "--fail", "--cacert", "/service-ca/service-ca.crt", "$2"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: service-ca, mountPath: /service-ca, readOnly: true}]
  volumes:
  - name: service-ca
    configMap: {name: openshift-service-ca.crt}
YAML
  if ! k wait pod "$pod" -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1; then
    k logs "$pod" -n "$NS" >&2 || true
    k get pod "$pod" -n "$NS" -o jsonpath='{.status.phase} {.status.containerStatuses[*].state}' >&2 || true
    rc=1
  else
    k logs "$pod" -n "$NS"
  fi
  k delete pod "$pod" -n "$NS" --ignore-not-found >/dev/null
  return $rc
}
```

If the live run shows `curl: not found` in that pod, switch the image to `quay.io/curl/curl:latest` (its entrypoint is curl; keep `command` as written).

- [ ] **Step 2: Extend `05-enable-nhc.sh`**

Replace the two `record 05-consoleplugin ...` and `record 05-servicemonitor ...` lines (and their `&& echo ... || echo ...` continuations) with the block below, keeping the lines before and after them:

```bash
# ---- OpenShift platform integration (D11): metrics mTLS (issue #3) ----
wait_for 300 "console backend Available" deployment_available node-healthcheck-node-remediation-console-plugin
expect "status lists both NHC Deployments ready" jcheck \
  'sorted(d["name"] for c in o["status"]["components"] if c["name"] == "nodeHealthCheck" for d in c["deployments"] if d["ready"]) == ["node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"]' \
  get workloadavailabilityconfig cluster
expect "service-ca issued the metrics serving Secret node-healthcheck-tls (key names only)" secret_has_keys "$NS" node-healthcheck-tls tls.crt tls.key
expect "service-ca issued the console serving Secret nrc-plugin-cert (key names only)" secret_has_keys "$NS" nrc-plugin-cert tls.crt tls.key
ca_injected_cm() { jcheck '"BEGIN CERTIFICATE" in ((o.get("data") or {}).get("service-ca.crt") or "")' get configmap node-healthcheck-ca-bundle -n "$NS"; }
wait_for 120 "service-ca injected service-ca.crt into node-healthcheck-ca-bundle" ca_injected_cm
expect "manager mounts the metrics serving certificate read-only at /etc/tls/private" jcheck \
  'any(m["mountPath"] == "/etc/tls/private" and m.get("readOnly") for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "manager" for m in c.get("volumeMounts") or [])' \
  get deployment node-healthcheck-controller-manager -n "$NS"
expect "manager log reports metrics mTLS configured" bash -c 'k logs deployment/node-healthcheck-controller-manager -n "$NS" --all-containers --tail=500 | grep -q "Configuring secure metrics with mTLS"'
wait_for 120 "NHC created its ServiceMonitor" found servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS"
expect "ServiceMonitor selector matches the metrics Service labels" sm_selects_service
expect "ServiceMonitor is owned by the manager Deployment (garbage-collected on disable)" jcheck \
  'any(r["kind"] == "Deployment" and r["name"] == "node-healthcheck-controller-manager" for r in o["metadata"].get("ownerReferences") or [])' \
  get servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS"
nhc_targets_up() { prom_all_values 'up{namespace="'"$NS"'",job="node-healthcheck-controller-manager-metrics-service"}' 1; }
wait_for 300 "platform Prometheus scrapes every NHC target (up == 1)" nhc_targets_up
no_rejected_sm() { prom_all_values 'prometheus_operator_managed_resources{job="prometheus-operator",namespace="openshift-monitoring",resource="ServiceMonitor",state="rejected"}' 0; }
wait_for 300 "Prometheus operator rejects no ServiceMonitor" no_rejected_sm
prom_query 'up{namespace="'"$NS"'"}' > "${RUN_DIR}/raw/05-prometheus-targets.json" || true
expect "the rejected-ServiceMonitor alert is not firing" bash -c '[ "$(prom_query "ALERTS{alertname=\"PrometheusOperatorRejectedResources\",alertstate=\"firing\"}")" = "[]" ]'

# ---- console backend (issue #4): trusted fetch, then the administrator enables the plugin ----
record 05-consoleplugin get consoleplugin node-remediation-console-plugin -o json >/dev/null
expect "ConsolePlugin backend points at the WAO-rendered Service" jcheck \
  'o["spec"]["backend"]["service"] == {"name": "node-healthcheck-node-remediation-console-plugin", "namespace": os.environ["NS"], "port": 9443, "basePath": "/"}' \
  get consoleplugin node-remediation-console-plugin
manifest=$(trusted_fetch 05-manifest "https://node-healthcheck-node-remediation-console-plugin.${NS}.svc:9443/plugin-manifest.json") || manifest=""
printf '%s\n' "$manifest" > "${RUN_DIR}/raw/05-plugin-manifest.json"
expect "plugin manifest served over TLS trusted by the service CA and names the plugin" \
  python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1])["name"] == "node-remediation-console-plugin" else 1)' "$manifest"
before_plugins=$(console_plugins)
enable_console_plugin 05-enable-plugin node-remediation-console-plugin   # administrator action, not WAO (known issue KI-1)
expect "plugin enabled in Console/cluster" console_plugin_enabled node-remediation-console-plugin
expect "previously enabled plugins preserved" python3 -c 'import json, sys; sys.exit(0 if set(json.loads(sys.argv[1])) <= set(json.loads(sys.argv[2])) else 1)' "$before_plugins" "$(console_plugins)"
console_rolled_out() {
  jcheck 'o["status"].get("observedGeneration") == o["metadata"]["generation"] and o["status"].get("readyReplicas") == o["spec"]["replicas"] and o["status"].get("updatedReplicas") == o["spec"]["replicas"] and not o["status"].get("unavailableReplicas")' \
    get deployment console -n openshift-console
}
sleep 30   # give the console operator time to pick up the new plugin list before checking the rollout
wait_for 600 "OpenShift console Deployment rolled out with the new plugin list" console_rolled_out
record 05-console-plugins get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' >/dev/null
echo "note: browser verification of the Node Remediation UI is manual (docs/known-issues.md KI-7)"
```

- [ ] **Step 3: Extend `15-disable-nmo-nhc.sh`**

After the `for pair ...; done` loop, add:

```bash
expect "WAO removed the CA ConfigMap it owned" absent configmap node-healthcheck-ca-bundle -n "$NS"
expect "WAO removed the console backend" absent deployment node-healthcheck-node-remediation-console-plugin -n "$NS"
# Administrator cleanup of what the harness enabled in WAO-INST-05 (WAO never edits Console/cluster, KI-1).
if console_plugin_enabled node-remediation-console-plugin; then
  others=$(console_plugins | python3 -c 'import json, sys; print(json.dumps([p for p in json.load(sys.stdin) if p != "node-remediation-console-plugin"]))')
  disable_console_plugin 15-disable-plugin node-remediation-console-plugin
  expect "plugin entry removed from Console/cluster, other entries preserved" [ "$(console_plugins)" = "$others" ]
fi
```

Remove the line `leftover "ConfigMap node-healthcheck-ca-bundle" configmap node-healthcheck-ca-bundle -n "$NS"` (it is WAO-owned now and asserted absent above). Extend the Secret loop to `for s in node-healthcheck-webhook-server-cert node-maintenance-operator-webhook-server-cert node-healthcheck-tls nrc-plugin-cert; do`.

- [ ] **Step 4: Best-effort removal in `18-uninstall.sh`**

Inside the existing `if k api-resources --api-group=console.openshift.io ...` block, before deleting the ConsolePlugin, add:

```bash
  disable_console_plugin 18-disable-plugin node-remediation-console-plugin || echo "note: could not edit the Console/cluster plugin list"
```

- [ ] **Step 5: Document the mutations**

`test/cluster/run-all.sh`, RUN.md heredoc, add under "Intended mutations":

```
- Enabling NHC also adds `node-remediation-console-plugin` to `Console/cluster` `spec.plugins` (administrator step,
  preserving other entries) and runs one short-lived curl pod in the install namespace; disabling NHC removes the entry.
```

`test/cluster/README.md` table: row 05 "Mutates" becomes `config patch; adds the plugin to Console/cluster spec.plugins; one short-lived curl pod`, row 15 becomes `config patch; removes the plugin entry from Console/cluster`. Add to Safety: "`05` edits `Console/cluster` only by appending or removing the single `node-remediation-console-plugin` entry; WAO itself never does (see docs/known-issues.md KI-1)."

- [ ] **Step 6: Syntax-check and commit**

Run: `make test-offline` (runs `bash -n` on every script) and `make test`. Expected: PASS.

```bash
git add test/cluster/lib.sh test/cluster/05-enable-nhc.sh test/cluster/15-disable-nmo-nhc.sh test/cluster/18-uninstall.sh test/cluster/run-all.sh test/cluster/README.md
git commit -m "wao: live checks for NHC metrics scraping and the console backend

05 verifies service-ca issuance, CA injection, ServiceMonitor selection,
Prometheus targets up, no rejected monitors, a trusted plugin manifest fetch,
then enables the plugin as an administrator would. 15 and 18 remove the entry.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/operands.md`, `docs/design-brief.md`, `README.md`, `docs/known-issues.md`

- [ ] **Step 1: `docs/operands.md`, NHC section**

Change the opening paragraph of the NHC section to:

```markdown
Bundle CSV `node-healthcheck-operator.v0.12.0`, taken from the OKD community bundle
(`quay.io/community-operator-pipeline-prod/node-healthcheck-operator@sha256:e7684ebb…`), which is the
published k8s bundle plus the console backend. Source tag commit
`a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`. The OpenShift metrics additions below come from that
commit's `config/manifests/ocp` and `config/optional/prometheus-ocp`, kept verbatim under
`hack/platform/nhc/` (design brief D11).
```

Add rows to the object table:

```markdown
| Deployment | `node-healthcheck-node-remediation-console-plugin` | 1 replica; service account `node-healthcheck-console-plugin` (`automountServiceAccountToken: false`); image `quay.io/medik8s/node-remediation-console:v0.12.0`; nginx on 9443 serving the dynamic console plugin; mounts service-ca Secret `nrc-plugin-cert` at `/var/serving-cert` |
| Service | `node-healthcheck-node-remediation-console-plugin` | 9443; serving-cert annotation for `nrc-plugin-cert`; the backend the NHC-created ConsolePlugin points at |
| CSV namespaced permissions | `node-healthcheck-console-plugin` | one no-op `configmaps` rule, present so OLM creates the ServiceAccount; also copied cluster-wide as `-all-namespaces` |
| ConfigMap | `node-healthcheck-ca-bundle` | `service.beta.openshift.io/inject-cabundle: "true"`; service-ca writes `service-ca.crt`; referenced by the NHC-created ServiceMonitor (D11) |
| Role and RoleBinding | `node-healthcheck-prometheus-k8s` | services, endpoints, pods, endpointslices get/list/watch for `openshift-monitoring/prometheus-k8s` (D11) |
```

Amend the metrics Service row to `8443 to https; WAO adds label app.kubernetes.io/instance=metrics and a serving-cert annotation for node-healthcheck-tls (D11)`, and the manager Deployment row's "no volumes" to `WAO mounts node-healthcheck-tls read-only at /etc/tls/private (D11) and the webhook certificate (D1)`. In the runtime-created table, change the ConsolePlugin note "which the upstream bundle does not ship" to "which WAO renders from the OKD bundle".

In the Images table add `| RELATED_IMAGE_NHC_CONSOLE | quay.io/medik8s/node-remediation-console:v0.12.0 | NHC console plugin backend |` and change "All seven images" to "All eight images".

- [ ] **Step 2: `docs/design-brief.md`, decision D11**

Append to the decisions table:

```markdown
| D11 | OpenShift platform supplements: where an upstream component publishes an OpenShift or OKD bundle built from the same tag, WAO pins that bundle; additions that exist only in upstream source (NHC's OCP metrics overlay) are applied from verbatim copies of the pinned commit's files under `hack/platform/<component>/`, recorded in provenance. WAO never edits `Console/cluster` or the component-created `ConsolePlugin`, and does not report them | The unchanged NHC manager assumes OpenShift packaging supplied its console backend and metrics TLS wiring; the published k8s bundle has neither. Console enablement and registration cleanup stay administrator actions (known issue KI-1) | Upstream bundles that carry the complete platform packaging |
```

Add to section 10 item 3, after "component label": ", and, for NHC on OpenShift, the platform supplements of D11".

- [ ] **Step 3: `README.md`**

Line 338: "lists the seven component images" becomes "lists the eight component images (seven managers and agents plus the NHC console plugin)". Where the README describes what enabling a component applies (around line 241), add "and, for NHC, the console backend Deployment and Service, the CA ConfigMap and Prometheus discovery RBAC (design brief D11)".

- [ ] **Step 4: `docs/known-issues.md`**

In KI-1, after the cleanup commands, add: "The live harness performs enablement in `test/cluster/05-enable-nhc.sh` and removal in `15-disable-nmo-nhc.sh`."

- [ ] **Step 5: Commit**

```bash
git add docs/operands.md docs/design-brief.md README.md docs/known-issues.md
git commit -m "wao: document the NHC platform supplements (D11)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Validate on the confirmed disposable cluster

**Files:**
- Create (git-ignored): `evidence/<UTC-date>-nhc-platform-*/` by the harness
- Modify at the end: `HANDOFF.md`; optionally commit sanitized `REPORT.md` and `results.json` after review

Preconditions: the user confirmed the cluster in this session; `KUBECONFIG` points at its file; the working tree is clean (every task committed); `.venv` exists.

- [ ] **Step 1: Uninstall the current installation**

The cluster runs WAO 0.1.0 with all six components enabled. Classic OLM will not upgrade a same-version CSV, so remove it first. This stops SNR agents and deletes the thirteen CRDs; both are expected on this disposable cluster.

```bash
export KUBECONFIG=/Users/jmatthews/git/jwmatthews/wao_poc/jmatthews-rc5-olmv1-oct09.kubeconfig
export RUN_DIR="$PWD/evidence/$(date -u +%F)-nhc-platform-uninstall"
bash test/cluster/run-all.sh 18
```

Expected: `WAO-INST-18` pass and the final preflight passes again. If a step hangs on finalizers the script already clears them and reports it.

- [ ] **Step 2: Build the WAO image and regenerate the bundle on this cluster**

```bash
unset RUN_DIR
CONFIRM=yes bash test/cluster/full-run.sh build
git status --short   # README.md, bundle CSV, config/manager/kustomization.yaml: the new digest
git add README.md bundle config/manager/kustomization.yaml
git commit -m "wao: point the POC bundle at the rebuilt WAO image

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Expected: the build phase runs `make bundles operand-manifests-check test test-offline` (if `make test` trips on KI-6, run the isolated-copy form yourself, then rerun with `SKIP_PREREQS=1` and say so), builds in `wao-poc-build`, regenerates the bundle and `dist/wao-poc-catalog.yaml`.

- [ ] **Step 3: Run the full install case**

```bash
export RUN_DIR="$PWD/evidence/$(date -u +%F)-nhc-platform-run"
bash test/cluster/run-all.sh
```

Expected: every case `pass` in `$RUN_DIR/results.json`. The checks that prove this plan are in case 05 (metrics targets up, no rejected ServiceMonitor, trusted manifest fetch, plugin enabled with others preserved, console rolled out), 11 (parity including the console Deployment and the platform contract), 12 (restart changes nothing), 13 (drift) and 15 (CA ConfigMap and console backend gone, plugin entry removed).

If 05 fails, debug from `$RUN_DIR/raw/case-05.log` and the recorded JSON; likely spots are the curl image (see Task 5 Step 1 fallback), Prometheus needing more than 300 s to reload, or the console rollout wait. Fix, rebuild (`run-all.sh 18`, then Step 2 again), rerun. Do not patch the cluster by hand to make a check pass.

- [ ] **Step 4: Manual browser check (user)**

Ask the user to open the OpenShift console, confirm `node-remediation-console-plugin` shows as loaded under the console's plugin list, and open the Node Health Checks pages. Record the outcome in `REPORT.md`. This is KI-7.

- [ ] **Step 5: Sanitize and report**

Write `$RUN_DIR/REPORT.md` by hand (the `run` phase of `full-run.sh` was not used): cluster release only as "OpenShift 5.0.0-rc.5", WAO commit, results table, the issue #3 and #4 acceptance criteria with pass/fail, and leftovers. Grep the report and `results.json` for API URLs, node names, IPs and the kubeconfig name before considering them for commit:

```bash
grep -nE 'https?://|\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b|kubeconfig|ip-[0-9]' "$RUN_DIR/REPORT.md" "$RUN_DIR/results.json" || echo "clean"
```

Only after the user reviews them, copy the two files to a tracked location they choose and commit.

- [ ] **Step 6: Update `HANDOFF.md` and commit**

Replace the second paragraph with the current state: metrics and console implemented in this branch (list commits), validated on a disposable OpenShift 5.0.0-rc.5 cluster on the run date, remaining items tracked in `docs/known-issues.md`. Replace "Recommended next steps" with a pointer to KI-1 through KI-7 and the spec. Keep the version table, adding the console image as pinned.

```bash
git add HANDOFF.md
git commit -m "wao: update the NHC platform handoff after validation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: P1, P2, P6 (Task 1); P3, P4, P5 (Task 2); P7 (no code; harness does enablement, Task 5; KI-1); P8 (Task 1 Deployments, Task 5 status check); P9 (Task 3). Spec 4.5 offline tests map to Tasks 1 to 4; live checks to Tasks 5 and 7; 4.6 docs to Task 6 and the known-issues file already committed.
- Every commit leaves `make test`, `make test-offline`, `make operand-manifests-check` and `make bundle-check` green: Task 1 bundles the release-set, extractor, Go binding, regeneration and bundle; Task 2 carries the parity tolerance with the manifests that need it.
- Names used across tasks: `images.NHCConsole`, `WAO_VOLUMES`, `check_platform_contract`, `platform_sources`, `--platform`, `trusted_fetch`, `enable_console_plugin`, `disable_console_plugin`, `console_plugins`, `prom_all_values` are each defined once and used with the same spelling.
- Review Focus items 1 to 5 each have a named test in Tasks 1, 2 and 3.
