# Issue #3: NHC metrics diagnosis, repair, and verification

**Status:** Fixed in the local source and verified on the authorized OpenShift cluster on 2026-10-16. All changes remain uncommitted on `issue3`, based on `e6fae32`. No GitHub state was changed.

The final read-only verification began at **22:20:48 UTC** and passed on its first scan: both NHC managers were ready and using mutual TLS; each of the two platform Prometheus replicas had two healthy NHC targets and two current-pod `up=1` samples. No target reported a scrape error. The rejected-resource alert had zero firing or pending instances. All eleven verification conditions passed.

The installed WAO CSV is `Succeeded`, all six components are `Available`, and the original component configuration is restored. The existing SNR configuration and node agent were preserved. The validated WAO image is stored in the cluster's internal registry and selected by digest, so its continued use does not depend on the temporary external registry used to transfer the build.

Machine-readable, sanitized evidence is in [issue-3-nhc-metrics-results.json](issue-3-nhc-metrics-results.json). The reusable procedure is in [nhc-metrics.md](nhc-metrics.md).

## The symptom and the misleading healthy status

[Issue #3](https://github.com/jwmatthews/wao_poc/issues/3) reported a rejected NHC ServiceMonitor and missing metrics, even though the NHC Deployment was ready. The current cluster reproduced that problem after the operand pins had been refreshed.

There are three distinct success conditions here:

1. Kubernetes can run the NHC managers and their readiness probes pass.
2. Prometheus accepts the ServiceMonitor and discovers the intended endpoint.
3. Prometheus successfully authenticates to that endpoint and records samples.

WAO's availability status checks the Deployment rollout and admission certificate readiness. It does not query Prometheus. A ready NHC Deployment therefore does not establish that monitoring works. This repair preserves that availability contract and adds a separate check for actual scraping.

The issue originally described NHC source commit `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`. The current running binary reported **`v0.12.0-95-gf130fa28`**, commit **`f130fa28d307003177ec38f27754ac3503a56ecc`**. Its manager digest matched the current `release-set.yaml`; its bundle CSV was named `node-healthcheck-operator.v5.8.0`. Bundle labels and binary version strings are different identifiers, so the investigation used the binary's reported source commit when reading upstream code.

## How the diagnosis narrowed the failure

The investigation followed the monitoring path from the rejected configuration back to its inputs.

| Observation before repair | What it established |
| --- | --- |
| Prometheus operator rejected `node-healthcheck-ca-bundle`, key `service-ca.crt`, as missing | The monitor referenced a CA resource that had never been created. |
| The monitor's selector matched zero Services | Supplying a CA alone could not produce scrape targets. |
| The intended metrics Service lacked `app.kubernetes.io/instance: metrics` | The missing label was on the Service's metadata, the layer selected by the ServiceMonitor. |
| The metrics Service had no serving-certificate annotation | OpenShift service-CA had not been asked to issue its server certificate. |
| The NHC Deployment had no `/etc/tls/private` certificate mount | Even an issued certificate would not reach the process. |
| Both managers logged missing mTLS certificates and bearer-authentication fallback | The running authentication mode did not match the monitor's client-certificate scrape class. |
| Prometheus exposed zero active NHC targets | The failure was observable end to end, rather than inferred from an alert alone. |

The operand namespace already had the platform-monitoring label, and the platform defined the `tls-client-certificate-auth` scrape class. Effective authorization checks confirmed the client-CA and discovery permissions already in use. These checks avoided adding RBAC to solve a packaging defect.

Next, the cached bundle and generated manifests were checked. The cache matched the release-set bundle reference and recorded file hashes; provenance matched its inputs; `make operand-manifests-check` said the outputs were current. The pinned bundle contained no metrics CA ConfigMap. Its generated Deployment had WAO's webhook certificate mount, but no metrics mount. This ruled out stale generation as the explanation.

Upstream's [OpenShift overlay](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/config/manifests/ocp/kustomization.yaml) supplies the missing CA, Service metadata, and metrics certificate mount. Its [ServiceMonitor code](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/internal/controller/servicemonitor/monitor.go) assumes those inputs exist. WAO consumed the pinned bundle's contents without restoring that part of the OpenShift packaging contract.

**Root cause:** WAO generated an incomplete OpenShift installation for the unchanged NHC binary. NHC correctly created a monitor for a metrics setup that WAO had not supplied.

## Understand the two selection steps and both TLS directions

The discovery chain is:

```text
Platform Prometheus
  -> selects the operand namespace and NHC ServiceMonitor
  -> ServiceMonitor.spec.selector selects Service metadata labels
  -> Service.spec.selector selects NHC pods
  -> the Service's named HTTPS port reaches each manager
```

The missing instance label affected the second step. Changing the Service's pod selector would not fix that missing Service metadata. The repair leaves the upstream pod selector and Service ports intact.

Mutual TLS adds two independent trust directions:

| Direction | Certificate and trust source |
| --- | --- |
| Prometheus verifies the NHC server | service-CA issues `node-healthcheck-tls` for the metrics Service DNS identity. The monitor reads `node-healthcheck-ca-bundle/service-ca.crt` to trust that issuer. |
| NHC verifies the Prometheus client | The platform scrape class supplies Prometheus's client certificate. NHC's dynamic client-CA controller reads `kube-system/extension-apiserver-authentication`, key `client-ca-file`. |

The metrics serving Secret is separate from the webhook Secret because the Services have different DNS identities. Reusing the webhook certificate would not establish the expected metrics server identity. Disabling certificate verification or changing webhook failure policies would bypass a check without supplying the missing contract.

The upstream [mTLS setup](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/internal/metrics/tls/configure.go) checks the certificate files during startup. If they are absent, the [main program](https://github.com/medik8s/node-healthcheck-operator/blob/f130fa28d307003177ec38f27754ac3503a56ecc/cmd/main.go) chooses bearer authentication. A certificate arriving later does not redo that initial mode selection. This makes startup ordering part of the fix.

## What changed in the source

The runtime change is small: a targeted generator addition and one ConfigMap watch.

### Restore the missing generated packaging

[`hack/extract-operand-manifests.py`](../hack/extract-operand-manifests.py) now calls `configure_nhc_metrics` for NHC. It adds:

- ConfigMap `node-healthcheck-ca-bundle` with `service.beta.openshift.io/inject-cabundle: "true"`.
- Metrics Service metadata label `app.kubernetes.io/instance: metrics`.
- Metrics Service annotation `service.beta.openshift.io/serving-cert-secret-name: node-healthcheck-tls`.
- A required metrics Secret volume and read-only manager mount:

```yaml
volumes:
- name: tls-config
  secret:
    secretName: node-healthcheck-tls
    optional: false
    items:
    - key: tls.crt
      path: tls.crt
    - key: tls.key
      path: tls.key
# In the manager container:
volumeMounts:
- name: tls-config
  mountPath: /etc/tls/private
  readOnly: true
```

The required Secret and explicit keys make Kubernetes wait for issuance before starting the manager. The directory mount has no `subPath`, so projected certificate updates remain visible to the upstream watcher.

The generated ConfigMap deliberately has **neither `data` nor `binaryData`** in WAO's apply payload. WAO creates its metadata and ownership reference; service-CA injects and maintains its contents. Copying live certificate data into WAO's desired object would blur that ownership boundary. Integration tests inspect managed fields and confirm that repeated apply does not claim or erase service-CA's data.

After regeneration, NHC has 13 manifests and the six operands have 91 in total. Provenance records the exact additions. Structural parity tests remove only the allowed WAO additions before comparing the remaining Deployment and Service with the upstream bundle. This makes an unrelated generator change fail reviewable tests.

### Recover deletion without waiting for another event

[`SetupWithManager`](../internal/controller/workloadavailabilityconfig_controller.go) now includes:

```go
Owns(&corev1.ConfigMap{}).
```

Without this watch, an Available component has no Progressing timer to recreate a deleted CA ConfigMap. The new integration test seeds an already-ready operand **before starting its manager**, so no Progressing requeue is scheduled. It then deletes the ConfigMap and requires recreation within ten seconds. The test failed with `NotFound` before the watch was added and passed afterward.

The existing renderer and reconciler supply the new object's install namespace, WAO labels, WAC owner reference, foreign-object guard, and disable/finalization cleanup. WAO does not create the certificate Secret or take over NHC's ServiceMonitor.

No component image, image pin, public API field, webhook failure policy, CRD, or RBAC rule changed.

## How the running installation was repaired

Only WAO was built. Its image contains the regenerated embedded manifests and the ConfigMap watch; all component operators continue using their original pinned images.

The existing classic-OLM CSV was updated to select the new WAO image. An intermediate pull failed because the local Podman image digest differed from the manifest digest actually published to the registry. Reading and hashing the registry's manifest identified the correct digest. The CSV and installing Deployment were aligned to that verified reference. This was an image-transfer issue, separate from the NHC defect.

The validated WAO image was then copied through an OpenShift build into the internal registry. The CSV now selects that internal image by digest. The verification ImageStream, BuildConfig, and completed Build remain available on the cluster. They contain the WAO image; no component was rebuilt. The internal image manifest digest is:

```text
sha256:6c91a89255f220224cde77b696928c6513745b9312efb0183471ff1b12064b22
```

WAO's own reconciliation created the CA ConfigMap and corrected the metrics Service and Deployment. The initial pod-template change caused one normal NHC rollout. Both replacement managers started with mTLS enabled, and Prometheus began collecting metrics.

The catalog was not republished and no GitHub changes were made. A future reinstall from the old catalog would still select its old WAO image; carrying this fix into a release requires building and publishing the revised WAO manager/bundle/catalog through the normal release process.

## Live recovery checks and their results

| Scenario | Verified result |
| --- | --- |
| Normal repaired installation | Two ready NHC managers; two healthy targets and two current `up=1` samples on each Prometheus replica. |
| Repeated reconciliation and WAO restart | CA UID and data preserved; NHC Deployment generation and template unchanged. |
| Delete only the WAO-owned CA ConfigMap | New object created and CA reinjected within 0.34 seconds of the recovery observation; NHC generation unchanged. |
| Disable NHC | Manager Deployment, metrics Service, CA ConfigMap, and Deployment-owned monitor removed. The service-CA serving Secret was also garbage-collected; its existence was checked with name-only output, with no values captured. |
| Re-enable NHC | Fresh resources and managers recovered healthy scraping. |
| Final state | Original WAC spec restored, all six components Available, CSV Succeeded, existing SNR config and agent retained, no NHC policy present. |

The cluster already had an SNR configuration and node agent. A fresh all-Disabled OLM installation and whole-WAC deletion were therefore covered through local envtest behavior rather than exercised live by removing unrelated operands. Foreign ConfigMap conflicts, disable/re-enable, and finalization cleanup have local integration coverage. Platform certificate rotation was not forced; rotated CA data preservation was simulated in envtest.

## A verifier that checks the outcome

[`test/openshift/check-nhc-metrics.py`](../test/openshift/check-nhc-metrics.py) checks the installed system using resource reads, logs, effective authorization checks, and GET-only queries inside existing Prometheus containers. It does not modify cluster resources or read Secrets. Every command receives an explicit kubeconfig and bounded timeouts; output contains sanitized booleans, counts, timestamps, and named failures.

```sh
python3 test/openshift/check-nhc-metrics.py \
  --kubeconfig "$WAO_TEST_KUBECONFIG" \
  --namespace openshift-workload-availability --timeout 300
```

Use a kubeconfig for the explicitly authorized cluster in the current session. Exit `0` means verified health; exit `1` means unhealthy or incomplete verification; exit `2` means invalid arguments. `--timeout 0` performs one bounded scan.

The checker requires positive evidence from **each** configured Prometheus replica: the exact monitor scrape pool, one healthy target per current ready manager, no target error, and a unique successful sample for each current pod. Failed queries, unavailable peers, and missing current targets cannot be hidden by a healthy peer or old data. The aggregate rejection alert is reported separately because another rejected monitor can cause the same alert.

Two integration details mattered while building this check:

1. **Check the configured discovery role.** This platform uses Endpoints. Requiring EndpointSlice permissions unconditionally produced a false failure even though scraping worked. The checker now follows a monitor override, then Prometheus's setting, then the Endpoints default. No RBAC was broadened.
2. **Account for Prometheus lookback after replacement.** Following disable/re-enable, one peer returned two healthy current-pod samples plus two deleted-pod samples approximately 274–279 seconds old. Its active targets were correct. The checker now restricts sample validation to the current ready pods, while independently requiring exact active-target coverage. Tests prove old samples cannot substitute for missing, duplicate, or failing current samples.

These are examples of checking the system's actual contract: configuration presence alone is insufficient, and a validation command can itself be too broad or use the wrong lifecycle assumptions.

## Local verification and review

| Check | Result on the final relevant code |
| --- | --- |
| `make test-offline` | **61 tests passed**, no skips, including 27 verifier tests. |
| `make test` | Go/controller/envtest suites passed, **87.8% controller coverage**. The overall command then exited `1` at `verify-no-changes` because the requested changes and existing local documents remain uncommitted. |
| `make operand-manifests-check` | Passed: outputs current. |
| `make bundle-check` | Passed: one WAO CSV, 13 owned CRDs, seven pinned operand image references. |
| `go test ./api/... ./internal/operands/... -count=1` | Passed. |
| `git diff --check` | Passed. |
| Source review | Packaging review and full review were clean; the subsequent historical-samples correction also received a clean scoped review. |

`make test` also regenerates/formats artifacts before checking repository cleanliness. Its dirty-tree rejection is distinct from a failed test. No commit, stash, or deletion of the user's local documents was used to make that guard pass. `HEAD` remains `e6fae32`; the index is unchanged.

The important regressions exercise behavior:

- Generator contract: failed on the absent CA resource before the fix; now checks the Service discovery/TLS contract, required certificate keys, lack of generated Secret/ServiceMonitor, effective client-CA RBAC, and narrow upstream parity.
- Controller integration: checks foreign-object preservation, injected/rotated data preservation, field ownership, default-disabled absence, disable/re-enable and finalization cleanup, and deletion recovery from an already Available state.
- Verifier integration: runs the real command against a strict executable `oc` fixture. The fixture rejects mutations, Secret reads, missing explicit kubeconfig/timeouts, and unexpected remote commands. Cases include unavailable peers, failed/malformed responses, missing targets, duplicate/down/missing current samples, historical samples, and discovery-role differences.

## A repeatable method for future fixes

1. **Establish the running identity.** Compare the running component digest with `release-set.yaml` and obtain the binary's reported source commit. Read source at that revision, including packaging overlays. A bundle's version string alone does not describe everything its runtime expects.
2. **Follow the complete chain.** Start with the rejecting controller's error. Check each referenced resource, selector, named port, DNS identity, certificate mount, authentication mode, and resulting target/sample. Resolving the first error can reveal a second independent blocker.
3. **Identify each writer.** Decide which fields belong to WAO, service-CA, the component, and monitoring. Use their established interfaces and keep foreign objects protected. A manual patch is useful diagnostic evidence, but durable desired state belongs in the generator and controller that own it.
4. **Prove the missing behavior locally.** Write a failing generator or integration test before the change. Ensure a recovery test cannot pass because an unrelated timer happened to reconcile the object. Regenerate rather than hand-editing embedded output, and review the resulting provenance.
5. **Build and deploy WAO alone.** Keep component pins and failure policies intact. Confirm the published manifest digest rather than assuming a local image digest is the registry's digest. For this session, the internal registry retains the validated artifact.
6. **Verify real scrapes and lifecycle behavior.** Check every Prometheus peer and every expected ready manager. Test ownership/data preservation, deletion recovery, restart and enable/disable only on an authorized disposable cluster. Keep unrelated native workloads intact and never create a remediation policy/request to test installation.

For local reproduction after a deliberate source change:

```sh
make python-env
make bundles
make operand-manifests
make operand-manifests-check
make test-offline
go test ./api/... ./internal/operands/... -count=1
make test
```

Review generated differences after these commands. Expect the documented clean-tree guard while intentionally keeping work uncommitted. Cluster deployment and the read-only checker require the separately authorized target and explicit kubeconfig; the repository contains no credentials or cluster-identifying details.

The decisions for this session were to retain the work uncommitted, preserve the existing SNR resources, keep the validated image in the internal registry, and scope samples to current pods while independently validating all active targets. Their practical limits are the intentional dirty-tree gate, local rather than live coverage for a fresh default install/whole-WAC finalization, retained image/build storage, and the explicit current-target checks that prevent history from hiding a current failure. The source, report, and sanitized evidence are ready for the user's review; no release, commit, push, PR, issue comment, or workflow run was performed.
