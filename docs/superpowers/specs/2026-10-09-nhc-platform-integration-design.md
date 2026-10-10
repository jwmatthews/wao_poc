# NHC OpenShift platform integration: metrics and console backend

Status: approved design, 2026-10-09. Implements
[issue #3](https://github.com/jwmatthews/wao_poc/issues/3) (metrics ServiceMonitor
rejected) and [issue #4](https://github.com/jwmatthews/wao_poc/issues/4) (console
plugin has no backend). Supersedes the "Recommended next steps" section of
[HANDOFF.md](../../../HANDOFF.md) for these two issues.

## 1. Problem

WAO extracts NHC from the published Kubernetes-flavoured bundle. On OpenShift the
unchanged NHC manager assumes the OpenShift packaging supplied three things the
Kubernetes bundle does not carry:

1. A console backend Deployment and Service behind the `ConsolePlugin` it registers.
2. Metrics mutual-TLS wiring: a service-ca injected CA ConfigMap, a metrics Service
   label and serving-cert annotation, and a serving-certificate mount in the manager.
3. Prometheus discovery permissions in the operand namespace.

Result today: a registered plugin with no backend, and a `ServiceMonitor` the platform
Prometheus rejects. WAO reports NHC `Available` while both are broken.

## 2. Goal and success criteria

Enabled NHC on OpenShift delivers working platform metrics and a working console plugin
through WAO's existing operand lifecycle. Success:

- Issues #3 and #4 acceptance criteria met, tests written first.
- A default all-Disabled installation still creates no NHC resource.
- On the confirmed disposable cluster: `node-healthcheck-ca-bundle` carries
  `service-ca.crt`, the ServiceMonitor selects the metrics Service, NHC scrape targets are
  up, the rejection metric clears, the console backend is ready and serves its plugin
  manifest over TLS that verifies against the service CA, and enabling the plugin
  rolls the OpenShift console out cleanly.
- Component images, webhook failure policies, the no-adoption rule and the public API are
  unchanged.

## 3. Decisions

| # | Decision | Reason |
| --- | --- | --- |
| P1 | NHC's bundle in `release-set.yaml` becomes the digest-pinned OKD community bundle `quay.io/community-operator-pipeline-prod/node-healthcheck-operator@sha256:e7684ebbcc543d8077fd218c7a1c9ce6c7ee622cce9d1806cd2672d792fcec72` | Verified byte-identical to the pinned k8s bundle for manager Deployment, RBAC, webhooks, CRD and Services; adds only the console Deployment, console Service, console ServiceAccount permissions, the `console.openshift.io/plugins` CSV annotation and a `replaces` field. The console therefore comes from a published artifact through the existing extractor, with no new rendering mechanism. |
| P2 | New image binding `RELATED_IMAGE_NHC_CONSOLE`: upstream `quay.io/medik8s/node-remediation-console:v0.12.0`, pinned `quay.io/medik8s/node-remediation-console@sha256:f58fed1feef835bef8ddf9c7ab7edd987b87162866f68d76abd7be47ca737c2d` | Same release tag as NHC v0.12.0; linux/amd64; plugin manifest declares version 0.12.0. Flows through the same env, CSV relatedImages, renderer substitution and `check_images` enforcement as the other seven images. |
| P3 | The OCP metrics overlay is applied by the extractor from verbatim copies of five upstream source files at NHC commit `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`, stored under `hack/platform/nhc/` | No published upstream bundle carries the OCP overlay (the downstream product bundle uses different images). Verbatim files keep provenance reviewable; their sha256 and the commit are recorded in `provenance.json`. Nothing is hand-encoded. |
| P4 | The upstream kube-system Role and RoleBinding are not rendered | WAO already grants the CSV's namespaced permissions cluster-wide (`-all-namespaces` ClusterRole, design brief D7), which covers get/list/watch of `kube-system/extension-apiserver-authentication`. Verified live with `oc auth can-i`. A test pins the reasoning. |
| P5 | The upstream `prometheus-k8s` Role and RoleBinding are rendered in the install namespace with their external subject unchanged | Parity with OpenShift packaging; grants EndpointSlice discovery the platform ServiceAccount otherwise lacks. |
| P6 | The console ServiceAccount is rendered with `automountServiceAccountToken: false` | Matches upstream `service_account.yaml`; the bundle cannot carry it because OLM creates ServiceAccounts from permissions. Recorded as a WAO modification. |
| P7 | WAO never reads or writes `Console/cluster`, never touches the NHC-created `ConsolePlugin`, and does not report either in status | Chosen by the user over reporting the stale registration as retained. Keeps WAO inside its ownership model (design brief section 4). Tracked in [known-issues.md](../../known-issues.md). |
| P8 | Console backend readiness is part of NHC's phase; console enablement is an administrator action | Both Deployments appear in `status.components[].deployments`. Enablement is documented and exercised by the cluster harness, preserving other `spec.plugins` entries. |
| P9 | The CA ConfigMap is a WAO-owned operand object applied with server-side apply; the injected `service-ca.crt` key is owned by service-ca and preserved | Issue #3 ownership proposal. A watch on owned ConfigMaps recreates it after deletion. |

## 4. Changes

### 4.1 Release set and images

- `release-set.yaml`: NHC `bundle` per P1 with a comment naming the community pipeline
  and the k8s bundle it extends; `images.RELATED_IMAGE_NHC_CONSOLE` per P2.
- `internal/images/images.go`: `NHCConsole` constant added to `Required`.
- `config/manager/manager.yaml` and the base CSV `relatedImages`: the new env and image.
- `bundle/` regenerated.

### 4.2 Platform supplement inputs

`hack/platform/nhc/` holds verbatim copies of, from the pinned NHC commit:

| File | Upstream path |
| --- | --- |
| `ca-configmap.yaml` | `config/optional/prometheus-ocp/ca-configmap.yaml` |
| `prometheus-k8s-role.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-role.yaml` |
| `prometheus-k8s-rolebinding.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-rolebinding.yaml` |
| `auth_proxy_service_patch.yaml` | `config/manifests/ocp/auth_proxy_service_patch.yaml` |
| `deployment_patch.yaml` | `config/manifests/ocp/deployment_patch.yaml` |

A `README.md` beside them states the repository, commit, the kustomize context they came
from (`namePrefix: node-healthcheck-`, namespace `system`) and that they are never edited.

### 4.3 Extractor

`hack/extract-operand-manifests.py` gains an NHC-only platform step driven by those files:

- `ca-configmap.yaml`: emit `ConfigMap/node-healthcheck-ca-bundle` in the install
  namespace with the inject-cabundle annotation and no data.
- `prometheus-k8s-role.yaml`, `prometheus-k8s-rolebinding.yaml`: emit
  `Role/node-healthcheck-prometheus-k8s` and its RoleBinding; the subject namespace
  `openshift-monitoring` is not a placeholder and stays.
- `auth_proxy_service_patch.yaml`: merge `metadata.labels` and `metadata.annotations`
  into the bundle's metrics Service.
- `deployment_patch.yaml`: append the patch's volume and volume mount to the manager
  container; assert the patch's `args` and `ports` equal the bundle's so upstream drift
  fails extraction.
- Console ServiceAccount: set `automountServiceAccountToken: false` (P6).
- `provenance.json`: a `platform_sources` entry per component listing upstream commit,
  path and sha256 of each file, plus the usual `wao_modifications` lines.

Kind ordering and the Python `ORDER`/Go `kindOrder` tables already cover ConfigMap, Role
and RoleBinding. The union role, pod component label, selector isolation and duplicate
identity checks run unchanged over the new objects.

### 4.4 Operator

- `internal/components/nhc.go`: `Deployments` lists
  `node-healthcheck-controller-manager` and
  `node-healthcheck-node-remediation-console-plugin`; `Images` adds the console binding.
- `internal/controller/workloadavailabilityconfig_controller.go`:
  `Owns(&corev1.ConfigMap{})`.
- `cmd/main.go`: cache `ConfigMap` only in the install namespace, like Deployment and
  Service.
- RBAC markers: WAO already holds `configmaps` create/delete and the union role gains the
  new rules automatically.

### 4.5 Tests

Offline, written before the implementation they cover:

- Extractor: console Deployment, Service, ServiceAccount, Role, RoleBinding and the
  `-all-namespaces` copy for the console ServiceAccount; console image is the upstream
  tag; metrics Service label and annotation; manager `tls-config` volume and mount with
  the Secret required; CA ConfigMap; `prometheus-k8s` Role and RoleBinding with the
  external subject intact; no kube-system objects and the all-namespaces role covering
  the client CA read; `automountServiceAccountToken: false`; provenance lists the
  platform sources with correct hashes; determinism.
- Images and renderer: the console image is required, substituted, and the manifests
  contain no unbound `quay.io/medik8s/` reference.
- Envtest: enabling NHC creates the console Deployment and the CA ConfigMap with the WAO
  owner reference and labels; a `service-ca.crt` key written by another field manager
  survives the next reconcile; deleting the ConfigMap triggers recreation; a pre-existing
  unmanaged `node-healthcheck-ca-bundle` makes NHC `Degraded` and is left untouched;
  disabling removes the console objects and the ConfigMap; status lists two Deployments.
- `hack/check-bundle.py`: already asserts every pinned image appears in the CSV env and
  `relatedImages`.
- `test/cluster/parity.py`: tolerate the `tls-config` volume and mount on the NHC
  manager; add an explicit NHC platform contract (metrics Service label and annotation,
  CA ConfigMap annotation, manager mount, console Service annotation and port) so a bare
  bundle on both sides can no longer pass.

Live cluster, `test/cluster/`:

- `05-enable-nhc.sh`: wait for both Deployments; `nrc-plugin-cert` and
  `node-healthcheck-tls` have `tls.crt` and `tls.key` (key names only); the CA ConfigMap
  has `service-ca.crt`; the ServiceMonitor selector matches the metrics Service; the
  platform Prometheus reports NHC targets `up` and no rejected-ServiceMonitor condition
  for the namespace; the manager log reports mTLS configured. Fetch
  `https://node-healthcheck-node-remediation-console-plugin.<ns>.svc:9443/plugin-manifest.json`
  from a short-lived pod in the install namespace with `curl --cacert` pointed at the
  namespace's `openshift-service-ca.crt` ConfigMap, so TLS trust is verified rather than
  skipped; the body must name the plugin. Then enable the plugin in `Console/cluster`
  with a JSON patch that preserves existing entries and wait for the console Deployment
  to roll out. The console's own plugin proxy cannot be exercised from a script: it
  requires a browser session, and bearer tokens are rejected (verified, HTTP 401).
- `15-disable-nmo-nhc.sh`: expect the CA ConfigMap and console backend absent; remove
  the plugin entry the harness added, preserving others; keep recording the
  `ConsolePlugin` as an upstream leftover.
- `18-uninstall.sh`: best-effort removal of the plugin entry.

### 4.6 Documentation

- New `docs/known-issues.md`: numbered entries with status, impact and revisit trigger.
  Initial entries: stale ConsolePlugin registration and manual console enablement (P7);
  EndpointSlice discovery role vs. the inspected Prometheus discovery mode; NHC upgrade
  needs APIServer TLS-profile RBAC; platform audit of SNR, SBR, FAR, MDR and NMO
  outstanding; must-gather and diagnostics not packaged; `make test` discovers foreign Go
  sources under ignored `evidence/`; browser-level console validation is manual.
- `docs/operands.md`: NHC section lists the OKD bundle, the console Deployment and
  Service, the platform additions and the console image.
- `docs/design-brief.md`: decision D11, "OpenShift platform supplements": published
  platform bundle where one exists, verbatim pinned source files otherwise, hands-off
  policy for `Console/cluster` and `ConsolePlugin`.
- `README.md` image table and `HANDOFF.md` status updated at the end.

## 5. Lifecycle summary

| Event | Effect |
| --- | --- |
| Install, all Disabled | No NHC object, no console, no ConfigMap. |
| Enable NHC | WAO applies RBAC, Services, ConfigMap, both Deployments, webhook configuration. Service-ca issues `node-healthcheck-tls`, `nrc-plugin-cert`, the webhook cert and injects the CA. NHC registers the ConsolePlugin and ServiceMonitor itself. Phase `Available` when both Deployments are ready and the webhook CA is injected. |
| Administrator enables plugin | Console loads the UI. Not observed or changed by WAO. |
| CA ConfigMap deleted or edited | Recreated or repaired by the ConfigMap watch; the injected key is preserved. |
| Disable NHC | WAO deletes what it rendered. The ServiceMonitor goes with the manager Deployment through its owner reference. The ConsolePlugin, the namespace monitoring label and any `Console/cluster` entry remain and are not reported. |
| Foreign object with a rendered name | NHC `Degraded`, object untouched, as today. |

## 6. Validation on the confirmed cluster

The CSV version stays 0.1.0, so classic OLM cannot upgrade in place. Sequence:
`run-all.sh 18` to uninstall the current installation, commit, `full-run.sh build`
(on-cluster image from `git archive HEAD`, bundle and catalog regenerated), then
`run-all.sh` for cases 00 to 18. Raw output stays under `evidence/`; only sanitized
`results.json` and `REPORT.md` are candidates for commit after review.

## 7. Out of scope

Reporting console enablement in status, automatic ConsolePlugin cleanup, platform audits
of the other five operands, must-gather, NHC upgrades, and browser automation. Each has a
known-issues entry.
