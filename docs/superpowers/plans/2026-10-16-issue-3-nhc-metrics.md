# Issue #3: NHC OpenShift Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This document is a proposal; the current session authorizes investigation and a local plan only.

**Goal:** Make the pinned NHC operand's existing OpenShift ServiceMonitor discover and successfully scrape its managers with mutual TLS.

**Architecture:** Restore the missing OpenShift metrics packaging in WAO's operand generator. WAO owns the CA ConfigMap metadata, metrics Service configuration, and manager certificate mount; OpenShift service-CA owns certificate issuance and injected CA data; upstream NHC continues to own its ServiceMonitor. Reuse WAO's renderer, server-side apply, ownership checks, and reverse-order cleanup.

**Tech Stack:** Python/PyYAML manifest generator; Go/controller-runtime; Kubernetes server-side apply and envtest; classic OLM; OpenShift service-CA and platform Prometheus.

**Spec:** [GitHub issue #3](https://github.com/jwmatthews/wao_poc/issues/3), repository `AGENTS.md`, and the investigation/design recorded in this document. Investigated against local HEAD `e6fae32` on 2026-10-16; cluster observations collected approximately 21:47–21:52 UTC.

## Global Constraints

- Do not modify, fork or rebuild the component operators. Consume the upstream images exactly as pinned in `release-set.yaml`, by digest.
- Every component defaults to `Disabled`. Installing WAO must not create a remediation policy, remediation request, native config or node agent.
- Never change a component webhook `failurePolicy`, in particular never `Fail` to `Ignore`.
- WAO never adopts an existing object it did not create. It reports the conflict instead.
- No public API field may override a component image.
- Always pass the kubeconfig explicitly; never rely on the current context.
- Never capture Secret values. Store no cluster credentials, endpoints, node identities, or cluster-identifying details in this repository.
- Future live mutation tests require a confirmed disposable OpenShift cluster with classic OLM and authorization to modify it. Cluster selection for this investigation does not establish disposability or authorize the future install/disable/restart scenarios below.
- Use server-side dry-run for admission checks. Never create a real `NodeHealthCheck`, `StorageBasedRemediationConfig`, `NodeMaintenance`, or remediation request during install verification.
- This plan remains local and uncommitted. No GitHub writes, code fixes, or cluster repairs were performed for this investigation. Any later GitHub write requires the exact action to be reviewed and explicitly approved, using `gh`.

---

## Investigation: what is running and what fails

### Current checkout differs from the issue's original snapshot

Issue #3 describes NHC source commit `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`. Commit `ad875e0` refreshed the operand pins on 2026-10-16. The selected cluster now runs the newer NHC image below and reproduces the same failure:

| Item | Observed value |
| --- | --- |
| NHC bundle pin | `quay.io/medik8s/node-healthcheck-operator-bundle@sha256:adb56ef51c843b7ff9de2021ec4ceb138bbe2c549cc1412fb02526ec4dd11fb6` |
| Cached NHC bundle CSV | `node-healthcheck-operator.v5.8.0` |
| Running NHC image, matching current `release-set.yaml` | `quay.io/medik8s/node-healthcheck-operator@sha256:663b732436fb0da81098502d6844321ec9d098b89186bbef47ee1ac3debb3ec4` |
| NHC version reported by both replicas | `v0.12.0-95-gf130fa28` |
| NHC source commit reported by both replicas | `f130fa28d307003177ec38f27754ac3503a56ecc` |
| WAO CSV referenced by the running Deployment | `workload-availability-operator.v0.1.0` |
| NHC manager | 2 ready replicas; service account `node-healthcheck-controller-manager` |
| WAO status | All six components Enabled and Available; NHC `admissionReady: true` |

The bundle version and the binary's reported version are different identifiers; do not infer source behavior from the `v5.8.0` bundle label. The running WAO manager uses a temporary image tag. Its exact binary build revision was not established; its configured operand image pins match this checkout. The commands originally used to install that binary cannot be recovered from Deployment state alone.

### Current failure evidence

1. `node-healthcheck-ca-bundle` is absent from the operand namespace. Prometheus operator logs at 21:47:36 UTC reject the NHC ServiceMonitor because `service-ca.crt` cannot be obtained from that ConfigMap.
2. The ServiceMonitor selects Services with `app.kubernetes.io/component=controller-manager`, `app.kubernetes.io/name=node-healthcheck-operator`, and `app.kubernetes.io/instance=metrics`. **Zero Services match.** The intended metrics Service lacks the third metadata label. Its existing pod selector is sufficient and should remain intact.
3. The metrics Service lacks `service.beta.openshift.io/serving-cert-secret-name`. The Deployment has only the separate webhook certificate volume/mount, with no mount at `/etc/tls/private`.
4. Both replicas logged `mTLS certificate not present, skipping mTLS configuration`, followed by `Using bearer-token authn/authz via controller-runtime`. The monitor requests scrape class `tls-client-certificate-auth`, whose configured client certificate authentication does not match this fallback.
5. A GET of Prometheus `/api/v1/targets?state=active` returned **zero NHC targets**. `ALERTS{alertname="PrometheusOperatorRejectedResources"}` returned a firing ServiceMonitor warning with value `1`. This alert is aggregated at the monitoring controller/resource level: it has `namespace=openshift-monitoring`, not the operand namespace. The operator logs establish the NHC rejection; the aggregate alert alone does not uniquely identify NHC.
6. The operand namespace already has `openshift.io/cluster-monitoring=true`, and the platform Prometheus defines `tls-client-certificate-auth` with certificate verification enabled. Namespace selection and scrape-class availability are not the missing pieces.
7. Effective authorization checks returned `yes` for NHC get/list/watch on ConfigMaps in `kube-system`, and Prometheus get/list/watch on Services, Endpoints, and Pods in the operand namespace. The generated NHC AllNamespaces role already supplies ConfigMap access. Do not add duplicate or broader RBAC as part of the repair. Include EndpointSlice authorization in future end-to-end validation if that discovery role is used.

### How the failure is produced

```text
release-set.yaml + cached digest-pinned NHC bundle
  -> hack/extract-operand-manifests.py
     copies CSV Deployment and bundle Services; adds webhook certificate wiring
     supplies no OpenShift metrics ConfigMap, Service patch, or certificate mount
  -> embedded internal/operands/manifests/nhc/*.yaml
  -> operands.Render(...) substitutes namespace/images and adds WAO labels
  -> ensureEnabled(...) checks ownership and server-side applies those objects
  -> NHC starts without /etc/tls/private/tls.crt and tls.key
     selects bearer-token authentication during startup
  -> NHC discovers OpenShift, labels its namespace, creates its ServiceMonitor
  -> platform Prometheus rejects the monitor for missing CA ConfigMap
     subsequent blockers would be empty Service discovery and incompatible TLS/auth
```

`ensureEnabled` determines availability from Deployment rollout and admission CA readiness; it does not validate metrics discovery or scraping. A ready manager and Available WAO status therefore do not contradict the metrics failure. Keep that status contract in this repair; prove metrics health in verification rather than introducing a Prometheus dependency into the public availability API.

The pinned bundle contains no ConfigMap. The cache's bundle reference matches `release-set.yaml` and generated provenance, all cached files match `fetch.json` hashes, and all input manifest hashes match provenance. `make operand-manifests-check` reports `outputs current`. The defect is deterministic generation of an incomplete OpenShift packaging contract, rather than stale generated files.

### Upstream reference checked at the running commit

All upstream reads used `gh api`; these links pin the source revision:

- [ServiceMonitor creation and selector/TLS contract](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/internal/controller/servicemonitor/monitor.go)
- [OpenShift packaging composition](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/config/manifests/ocp/kustomization.yaml)
- [Metrics Service annotation and label patch](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/config/manifests/ocp/auth_proxy_service_patch.yaml)
- [Metrics certificate volume and mount](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/config/manifests/ocp/deployment_patch.yaml)
- [Service-CA injection ConfigMap](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/config/optional/prometheus-ocp/ca-configmap.yaml)
- [mTLS setup and dynamic client CA source](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/internal/metrics/tls/configure.go)
- [Startup authentication selection and nonleader client-CA controller](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/cmd/main.go)

`ConfigureMTLS` checks both certificate files once before manager creation. With them present it enables required client certificates and watches `kube-system/extension-apiserver-authentication`, key `client-ca-file`. If files are absent it selects bearer authentication. A required Secret volume with explicit required keys prevents the process from starting before service-CA supplies those files. Use a directory mount, without `subPath`, so projected certificate updates remain visible.

The upstream overlay also contains a dedicated kube-system Role/RoleBinding, but WAO already grants the necessary effective access through its existing AllNamespaces translation. Reproduce the missing metrics contract, not the entire OpenShift overlay or unrelated console plugin resources. The exact upstream process that produced the published bundle remains unestablished; a standalone installation was not tested.

### Checks run during investigation

| Check | Result |
| --- | --- |
| `make test-offline` | Passed, 31 tests, no skips reported |
| `make operand-manifests-check` | Passed: `outputs current` |
| `go test ./internal/operands/...` | Passed (Go reported cached result) |
| Local inspection of all four missing packaging elements | All four absent |
| Read-only cluster manifests, NHC startup logs, Prometheus logs/targets/alert, authorization checks | Reproduced observations above |

No new regression tests or fixes were added. Full `make test` was not run: this deliverable changes only documentation, and that target also tidies/vendors/formats/regenerates and checks for a clean working tree. Passing existing tests demonstrates the coverage gap, not successful metrics behavior.

## Design decision

| Approach | Assessment |
| --- | --- |
| **Generate the missing NHC OpenShift metrics packaging in WAO** | Recommended. Implements the pinned binary's expected contract, preserves upstream ownership, and survives reconciliation/upgrades. |
| Create only the CA ConfigMap, or manually patch live resources | Incomplete. A CA-only repair leaves discovery and authentication broken; manual patches are outside the generator's desired state. |
| Replace/edit NHC's ServiceMonitor, weaken TLS, or rebuild/change the operand | Competes with upstream reconciliation or violates project constraints. |

This POC already depends on OpenShift service-CA for enabled NHC's required webhook certificate. Add the metrics wiring to the same enabled-operand path; do not introduce platform discovery or a new API setting solely for this repair. The existing all-Disabled Kind smoke path must stay independent of OpenShift certificates. Supporting enabled NHC on generic Kubernetes is a separate design.

Desired objects and responsibility:

| Resource/field | Owner and desired behavior |
| --- | --- |
| ConfigMap `node-healthcheck-ca-bundle` | WAO creates it in the operand namespace with injection annotation and existing ownership labels/reference. Omit `data` and `binaryData` from WAO's apply payload. |
| ConfigMap `data.service-ca.crt` | service-CA injects and maintains it. WAO never copies the certificate, clears it, or takes field ownership of it. |
| Metrics Service metadata | Add `app.kubernetes.io/instance: metrics` and request `node-healthcheck-tls` through the serving-cert annotation. Preserve existing Service ports and pod selector. |
| Secret `node-healthcheck-tls` | service-CA issues/manages it. WAO neither renders a Secret nor reads its values. Do not reuse the webhook Secret, which has a different Service identity. |
| NHC manager pod | Required `tls-config` Secret volume, keys `tls.crt` and `tls.key`, mounted read-only at `/etc/tls/private`; preserve webhook volume, args, images, replicas, and resource limits. |
| ServiceMonitor | NHC creates/updates it and owns it through its Deployment. WAO does not render/adopt it. |
| ConfigMap deletion event | Add an owned-ConfigMap watch so WAO recreates the deleted object even after the component is Available. Disable/finalization removes only WAO-managed resources through existing cleanup. |

## File map

| File | Intended change |
| --- | --- |
| `hack/extract-operand-manifests.py` | One NHC-specific metrics packaging function and call; record exact provenance modifications. |
| `hack/extract_operand_manifests_test.py` | Assert CA metadata/data omission, Service selection contract, required certificate keys/mount, effective RBAC, deterministic output and narrow upstream differences. |
| `internal/operands/render_test.go` | Assert new ConfigMap namespace/WAO labels and preserved NHC image substitution/certificate separation. |
| `internal/operands/manifests/nhc/30-ConfigMap-node-healthcheck-ca-bundle.yaml` | Generated new operand object. |
| `internal/operands/manifests/nhc/40-Service-node-healthcheck-controller-manager-metrics-service.yaml` | Generated metrics Service metadata additions. |
| `internal/operands/manifests/nhc/50-Deployment-node-healthcheck-controller-manager.yaml` | Generated required metrics certificate wiring. |
| `internal/operands/manifests/provenance.json` | Generated hashes and explicit metrics exceptions. |
| `internal/controller/workloadavailabilityconfig_controller.go` | Add `Owns(&corev1.ConfigMap{})`; retain existing SSA ownership/cleanup behavior unless integration tests expose a defect. |
| `internal/controller/workloadavailabilityconfig_controller_test.go` | CA ownership/conflict, injection preservation, deletion recovery, cleanup, and no default CA resource. |
| `test/openshift/check-nhc-metrics.py` | New narrowly scoped read-only verification command for an already installed/enabled NHC. |
| `hack/nhc_metrics_check_test.py`, `Makefile` | Offline fixture tests for the verifier; include them in `test-offline`. |
| `docs/nhc-metrics.md`, `README.md` | Document packaging ownership, verification, lifecycle checks, and NHC count change from 12 to 13 (total 90 to 91). |

Do not resurrect the deleted `test/cluster` harness. The issue's `test/cluster/05-enable-nhc.sh` and original parity scripts were removed in `c4f72c5`. `test/e2e/e2e_test.go` is an all-Disabled Kind smoke suite; it cannot establish OpenShift metrics acceptance. At this HEAD, `Makefile` has no `test-e2e` target and `e2e-test` only prints `not yet implemented`; do not use either as evidence that this bug is covered. Fixing those broader stale references is outside this plan.

## Task 1: Generate and verify the complete metrics packaging

**Files:** Generator, extraction tests, renderer tests, and the four generated paths listed above.

**Interfaces:** Add `configure_nhc_metrics(objects, mods) -> None` to the generator. It mutates only the already assembled NHC objects and records modifications. `operands.Render` retains its current interface and supplies the new object automatically.

- [ ] Add this extraction regression to `ExtractionTest`, then run it before changing the generator:

```python
def test_nhc_openshift_metrics_contract(self):
    cm = next(d for d in self.kinds(self.nhc, "ConfigMap")
              if d["metadata"]["name"] == "node-healthcheck-ca-bundle")
    self.assertEqual(cm["metadata"]["namespace"], "__WAO_NAMESPACE__")
    self.assertEqual(cm["metadata"]["annotations"],
                     {"service.beta.openshift.io/inject-cabundle": "true"})
    self.assertNotIn("data", cm)
    self.assertNotIn("binaryData", cm)
    svc = next(d for d in self.kinds(self.nhc, "Service")
               if d["metadata"]["name"] ==
               "node-healthcheck-controller-manager-metrics-service")
    self.assertEqual(svc["metadata"]["labels"]["app.kubernetes.io/instance"], "metrics")
    self.assertEqual(svc["metadata"]["annotations"]
                     ["service.beta.openshift.io/serving-cert-secret-name"],
                     "node-healthcheck-tls")
    dep = self.kinds(self.nhc, "Deployment")[0]
    pod = dep["spec"]["template"]["spec"]
    volume = next(v for v in pod["volumes"] if v["name"] == "tls-config")
    self.assertEqual(volume["secret"], {
        "secretName": "node-healthcheck-tls", "optional": False,
        "items": [{"key": "tls.crt", "path": "tls.crt"},
                  {"key": "tls.key", "path": "tls.key"}],
    })
    manager = next(c for c in pod["containers"] if c["name"] == "manager")
    mount = next(m for m in manager["volumeMounts"] if m["name"] == "tls-config")
    self.assertEqual(mount, {"name": "tls-config", "mountPath": "/etc/tls/private",
                             "readOnly": True})
```

Run: `.venv/bin/python -m unittest hack.extract_operand_manifests_test.ExtractionTest.test_nhc_openshift_metrics_contract -v`. Expected before repair: failure because the ConfigMap is absent. Ensure the bundle-dependent suite executes rather than skips.

- [ ] Add the following generator function and invoke it only when `name == "nhc"`, after assembling `objects` and before assigning `rendered[name]` in `main`:

```python
def configure_nhc_metrics(objects, mods):
    objects.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {
        "name": "node-healthcheck-ca-bundle", "namespace": NAMESPACE_PLACEHOLDER,
        "annotations": {INJECT_CABUNDLE_ANNOTATION: "true"},
    }})
    svc = next(o for o in objects if o["kind"] == "Service" and
               o["metadata"]["name"] == "node-healthcheck-controller-manager-metrics-service")
    svc["metadata"].setdefault("labels", {})["app.kubernetes.io/instance"] = "metrics"
    svc["metadata"].setdefault("annotations", {})[SERVING_CERT_ANNOTATION] = "node-healthcheck-tls"
    dep = next(o for o in objects if o["kind"] == "Deployment" and
               o["metadata"]["name"] == "node-healthcheck-controller-manager")
    pod = dep["spec"]["template"]["spec"]
    pod.setdefault("volumes", []).append({"name": "tls-config", "secret": {
        "secretName": "node-healthcheck-tls", "optional": False,
        "items": [{"key": "tls.crt", "path": "tls.crt"},
                  {"key": "tls.key", "path": "tls.key"}],
    }})
    manager = next(c for c in pod["containers"] if c["name"] == "manager")
    manager.setdefault("volumeMounts", []).append({
        "name": "tls-config", "mountPath": "/etc/tls/private", "readOnly": True,
    })
    mods.extend([
        "ConfigMap/node-healthcheck-ca-bundle: added service-ca injection metadata; certificate data is externally managed",
        "Service/node-healthcheck-controller-manager-metrics-service: added metrics instance label and serving-cert annotation for node-healthcheck-tls",
        "Deployment/node-healthcheck-controller-manager: added required metrics certificate keys at /etc/tls/private",
    ])
```

Do not add a rendered Secret, ServiceMonitor, image override, namespace mutation, or RBAC grant. A future incompatible bundle should fail these explicit contract tests and require deliberate review.

- [ ] Extend `TestRenderNHCReplacesNamespaceImagesAndLabels` with `find(t, objs, "ConfigMap", "node-healthcheck-ca-bundle")`; its existing loop must verify the new object's namespace and labels. Assert that the rendered ConfigMap has neither `data` nor `binaryData`, and that both distinct webhook/metrics mounts remain.
- [ ] Add a structural parity regression: deep-copy the cached NHC CSV Deployment, remove only the two WAO certificate volumes/mounts and WAO pod component label from the generated Deployment, and compare the remaining Deployment spec with the CSV spec. For the metrics Service, remove only the new instance label, serving-cert annotation, and namespace substitution before comparing with the cached Service. Assert precisely one additional ConfigMap and no generated Secret/ServiceMonitor. Assert the existing generated bound ClusterRole contains get/list/watch on ConfigMaps; keep the current union-role test unchanged. Reject unrelated differences, rather than adding a blanket parity exemption.
- [ ] Run `make operand-manifests`, then `make operand-manifests-check`, `make test-offline`, and `go test ./internal/operands/... -count=1`. Confirm output is 91 operand manifests, including 13 for NHC; review provenance and verify that no image pins, webhook policies, other operand manifests, CRDs, or union RBAC changed.

## Task 2: Prove safe ConfigMap reconciliation and recovery

**Files:** Controller and controller tests above. **Interface:** Add an owned ConfigMap event source to the existing reconciler; no new API or helper service.

- [ ] Before the existing successful NHC-enable test, add a conflict case: create an unlabelled ConfigMap named `node-healthcheck-ca-bundle` containing a sentinel value, enable NHC, and wait for `Degraded` with the existing `not managed by` message. Assert unchanged UID, data, labels, and owner references. Disable NHC, assert the foreign ConfigMap remains unchanged, then explicitly delete the test fixture. This test must fail before the new object is generated.
- [ ] In the normal NHC-enable test assert the new ConfigMap has the WAO managed-by/component labels, WAC controller owner reference, injection annotation, and no initial data. Extend the initial all-Disabled test and disable test to assert this ConfigMap is absent.
- [ ] Add an envtest injection/preservation case after enable. Simulate service-CA with a different field manager; force two reconciliations and assert the certificate survives. The essential operations, using current suite helpers and imports, are:

```go
key := types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}
cm := &corev1.ConfigMap{}
Expect(k8sClient.Get(ctx, key, cm)).To(Succeed())
base := cm.DeepCopy()
cm.Data = map[string]string{"service-ca.crt": "envtest-service-ca"}
Expect(k8sClient.Patch(ctx, cm, client.MergeFrom(base),
    client.FieldOwner("service-ca-test"))).To(Succeed())
r := &WorkloadAvailabilityConfigReconciler{
    Client: k8sClient, Scheme: k8sClient.Scheme(), Namespace: ns, Images: testImages(),
}
def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
for i := 0; i < 2; i++ {
    _, err := r.ensureEnabled(ctx, getWAC(ctx), def)
    Expect(err).NotTo(HaveOccurred())
    Expect(k8sClient.Get(ctx, key, cm)).To(Succeed())
    Expect(cm.Data["service-ca.crt"]).To(Equal("envtest-service-ca"))
}
```

Add the existing `internal/components` package to the test imports. Repeat with a changed sentinel to simulate CA rotation. Inspect ConfigMap managed fields and assert WAO does not own `data.service-ca.crt`. Reconstructing the reconciler exercises an independent apply path; use a real WAO process restart for the later live acceptance check.

- [ ] Add a deletion/recreation regression that cannot pass merely due to the existing 30-second Progressing requeue. In envtest, set the NHC Deployment status to the desired observed generation, updated replicas, and ready replicas, and inject a valid test CA into its webhook configuration until NHC reports Available. Generate that test-only PEM using Go's `crypto/rsa`, `crypto/x509`, and `encoding/pem`; never use cluster certificate material. After the controller queue settles, delete the owned ConfigMap and require recreation with a new UID within 10 seconds. Leave component state unchanged. Without a ConfigMap watch this should time out. Also assert repeated no-op reconciliation does not change the NHC Deployment generation/template.
- [ ] Add the single event-source line in `SetupWithManager` alongside the other owned resources:

```go
Owns(&corev1.ConfigMap{}).
```

Keep certificate data absent from the desired manifest. Existing SSA should preserve service-CA-owned fields; do not copy live data into WAO's apply object or add force ownership for certificate fields. If the real-apiserver preservation test fails, inspect managed fields and fix the narrowly demonstrated apply behavior before proceeding.

- [ ] Extend NHC disable assertions to include ConfigMap deletion; re-enable and verify recreation. The live finalization check below covers Kubernetes garbage collection of NHC's monitor and service-CA's generated Secret, which envtest does not run. Run controller envtest directly with isolated local assets, then the full required checks in Task 4.

## Task 3: Add a focused metrics verifier and its offline tests

**Files:** Create `test/openshift/check-nhc-metrics.py`, `hack/nhc_metrics_check_test.py`, and `docs/nhc-metrics.md`; modify `Makefile`'s `test-offline` command and the task-related README sections.

**Interfaces:** `python test/openshift/check-nhc-metrics.py --kubeconfig PATH --namespace NS --timeout 300` verifies an already enabled NHC without changing cluster resources. Require the kubeconfig argument, reject unreadable paths, and append `--kubeconfig` and a bounded `--request-timeout` to every `oc` call. Return 0 on verified health, 1 on unhealthy/timeout, and 2 for invalid arguments. Export `evaluate(snapshot: dict) -> list[str]` for fixture tests; the list contains named unmet conditions, with no raw cluster identities or certificate contents.

- [ ] Write fixture tests first. Include: all conditions healthy; missing/empty injected CA; nonmatching Service metadata; missing metrics volume or keys; absent scrape class; zero targets; one unhealthy replica among otherwise healthy targets; nonempty target `lastError`; rejection of this monitor; unrelated aggregate rejection alert; missing kubeconfig; malformed/failed API response. A query/API failure must fail verification rather than count as zero unhealthy targets.
- [ ] Keep the verifier's evaluation separate from I/O. Use the following target checks as the core, with fixtures matching this normalized contract:

```python
def evaluate(snapshot):
    failures = []
    for key in ("ca_populated", "service_matches", "certificate_wired",
                "mtls_enabled", "scrape_class_present", "monitor_accepted"):
        if not snapshot[key]:
            failures.append(key)
    expected = set(snapshot["ready_pod_ids"])
    targets = snapshot["nhc_targets"]
    if not expected or {t["pod_id"] for t in targets} != expected:
        failures.append("target_coverage")
    if len(targets) != len(expected):
        failures.append("target_count")
    if any(t["health"] != "up" or t["lastError"] for t in targets):
        failures.append("target_health")
    if snapshot["nhc_up_count"] != len(expected):
        failures.append("scrape_samples")
    return failures
```

`ready_pod_ids` and target `pod_id` are transient comparison values derived from the live ready NHC pods and target discovery labels; do not serialize those identities. Normalize API responses into this shape, use monotonic polling with a 5-second interval, and never treat missing Prometheus data as success.

- [ ] Implement read-only collection: get the named ConfigMap and assert a nonempty key without printing its contents; get the intended Service and NHC-created ServiceMonitor and verify selector match, CA reference, server name, port, scheme, and scrape class; inspect the Deployment's required Secret keys/mount; inspect each ready NHC pod's startup mode; check the namespace label, platform scrape class, and effective discovery/client-CA permissions. Emit booleans and counts only. Do not get Secrets.
- [ ] Query platform Prometheus from its existing `prometheus-k8s` pods using `oc exec ... -c prometheus -- curl -fsS` against localhost `/api/v1/targets?state=active` and `/api/v1/query`. Use GET only, no token extraction or remote installation. Scope targets to `serviceMonitor/<operand-namespace>/node-healthcheck-controller-manager-metrics-monitor/0`; require exactly one healthy target per ready NHC replica and successful `up{namespace="<operand-namespace>",service="node-healthcheck-controller-manager-metrics-service"}` samples. Check each available Prometheus replica; bound the polling timeout and require at least one successful query source, reporting any unavailable replica explicitly.
- [ ] Acceptance needs positive evidence that this monitor is accepted: healthy targets plus successful samples, and no new rejection events/log entries for it after the verification start time. Historical Warning events alone must not fail a repaired deployment. Query the aggregate rejected-resource alert separately and report its state. If other monitors are rejected, report that fact without attributing their alert to NHC or weakening this monitor's checks.
- [ ] Prove the command is read-only in offline tests by supplying a fake `oc` executable that records arguments and serves fixture output. Reject any invocation of apply/create/patch/delete/rollout/label, any Secret read, or any `exec` command except the expected GET-only curl queries. Test a missing kubeconfig fails before any command is launched. Add `hack/nhc_metrics_check_test.py` to `test-offline` and run it.
- [ ] Document the command, fields maintained by each controller, CA preservation, required startup keys, expected NHC=13/total=91 manifest counts, and the lifecycle runbook below. Keep this checker outside the all-Disabled Kind suite. Do not add a wide TLS/metrics framework or revive the removed install harness.

## Task 4: Verify generated artifacts and package the WAO change

**Files:** Task 1–3 changes; generated WAO bundle/config files only if normal regeneration changes them. **Interface:** Existing Make targets and unchanged `release-set.yaml` pins.

- [ ] Run the new extraction, renderer, controller, and verifier tests; confirm the relevant new tests failed on the old behavior before claiming regression coverage. Run `make test-offline`, `make operand-manifests-check`, `go test ./api/... ./internal/operands/... -count=1`, and `make bundle-check`.
- [ ] Build only the WAO manager/bundle using the existing build process. Keep all operand images pinned to the exact current digests and verify the built CSV's related images. No upstream operator build, overlay-wide import, or temporary operand-image substitution is needed.
- [ ] Run `make test` and `make test-offline` before any eventual task commit, as required by `AGENTS.md`. `make test` currently ends in `verify-no-changes`, which rejects any uncommitted/untracked file, and it invokes regeneration/formatting beforehand. Account for that existing behavior explicitly: first run in a preserved implementation checkout, inspect generated differences, and distinguish test failures from its expected dirty-tree gate. Re-run on a clean verification copy of the candidate tree, outside the user's checkout and without local-only documents, so the entire target can finish successfully before committing. Do not remove/stash the user's unrelated files or this local plan to satisfy the gate. Do not silently substitute a narrower command for the full required target.
- [ ] Review the final diff. Expected runtime changes are the one new ConfigMap, the metrics Service metadata, the required metrics volume/mount, and the ConfigMap watch. Confirm unchanged API defaults, webhook failure policies, upstream image pins, Service pod selector/ports, and non-NHC desired manifests. Provenance must describe exactly the exceptions under test. Bundle/RBAC regeneration should not introduce unrelated changes.
- [ ] If implementation is subsequently authorized, organize small local commits around independently verified generator, controller, and verification/doc changes. This investigation makes no commits. Pushing, PR creation/editing, workflow execution, and issue comments each still need specific GitHub-write approval.

## Task 5: Validate the repair on a confirmed disposable OpenShift cluster

**Files:** `docs/nhc-metrics.md` runbook; sanitized local `REPORT.md`/`results.json` only. **Interface:** The checker from Task 3 plus separately authorized WAO installation/lifecycle operations.

- [ ] Confirm the target is disposable, classic OLM and service-CA/platform monitoring are available, and install/upgrade/lifecycle mutations are authorized. Use a session variable pointing to the selected local kubeconfig and pass it explicitly on every command. Do not put the path, credentials, cluster endpoints, or node identities in committed artifacts.
- [ ] Capture a sanitized before-state using the read-only checker. Record missing elements, target count, and monitor rejection; never store Secret values. Abort lifecycle scenarios if existing policies, native configs, remediation requests, maintenance objects, or node agents make disable/re-enable unsafe for this test.
- [ ] Install/upgrade the candidate WAO through classic OLM. Test a fresh all-Disabled installation first: no NHC Deployment, Service, CA ConfigMap, generated metrics Secret, or ServiceMonitor should appear. Explicitly enable only NHC for the focused scenario, without creating any native policy/config/request. Then run:

```sh
python3 test/openshift/check-nhc-metrics.py \
  --kubeconfig "$WAO_TEST_KUBECONFIG" \
  --namespace openshift-workload-availability --timeout 300
```

The variable is supplied only at execution time and deliberately has no cluster-specific value in this document.

- [ ] Require service-CA to populate `service-ca.crt`, the monitor to select exactly the intended metrics Service, and both manager replicas to report mTLS enabled. Require two healthy target endpoints per Prometheus replica, positive matching `up` samples, and no TLS/auth errors. Require this monitor's rejection to cease; allow the alert evaluation window to elapse and verify the aggregate alert resolves if this was its only cause.
- [ ] Run repeated no-op reconciliations and restart WAO once. Compare the CA data hash, ConfigMap ownership, Deployment generation/template, and healthy target counts before/after. CA contents must survive and the NHC Deployment must not roll unnecessarily. The newly configured metrics volume should cause one normal NHC rollout when the fix is first applied.
- [ ] Delete only the WAO-owned CA ConfigMap and verify automatic recreation/reinjection while NHC remains Available, without touching WAC state. Re-run the checker after the transient injection/reload window. This intentionally mutating recovery scenario is part of future authorized testing, not this investigation.
- [ ] Disable NHC and require deletion of the WAO-owned CA ConfigMap and manager resources; require the Deployment-owned ServiceMonitor to be garbage-collected and service-CA-owned Secret to follow its Service ownership. Never claim WAO directly owns the generated Secret. Re-enable and require a fresh healthy scrape. In a separate default/finalization scenario, delete the WAC and verify cleanup while WAO and its RBAC still exist. Preserve any foreign conflicting object throughout.
- [ ] Review sanitized booleans/counts/timestamps for `REPORT.md` and `results.json`. Keep raw cluster output outside this repository; the current checkout's `.gitignore` does not ignore `evidence/`. Commit sanitized summaries only after review, if later requested. Do not attach raw logs or credentials to GitHub.

## Completion criteria and limits

- [ ] All required local checks pass and new tests demonstrate the previously missing contract and watch behavior.
- [ ] NHC's runtime monitor remains upstream-owned, selects its intended Service, and obtains its CA from a WAO-owned injection ConfigMap whose data stays service-CA-owned.
- [ ] Required metrics certificate files exist before manager startup; each replica uses mTLS and is actually scraped successfully.
- [ ] CA reinjection, steady-state apply, WAO restart, disable/re-enable, and finalization behave as specified without repeated unnecessary NHC rollouts or foreign-object adoption.
- [ ] Default all-Disabled behavior, current image digests, webhook failure policies, and API image restrictions remain intact.
- [ ] No real remediation policy/request, native config, maintenance object, or node agent was created for verification.

The repair remains proposed. It has not been applied or proven on a live cluster. Certificate rotation should be observed through normal service-CA operation and upstream file watchers; this plan does not rotate platform certificates or delete serving Secrets to force rotation. Generic Kubernetes enabled-operand support, upstream bundle build provenance, the broader stale README/test target cleanup, and public metrics-readiness API changes remain outside scope.
