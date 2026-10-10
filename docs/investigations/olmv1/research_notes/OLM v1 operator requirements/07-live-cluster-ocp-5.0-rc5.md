# Live read-only inspection of OLM v1 on the OCP 5.0 rc5 test cluster, 2026-10-10 UTC

Scope note: read-only inspection (no create, patch, delete, scale or restart; one `--dry-run=server`
apply) of the OCP 5.0 rc5 test cluster, reported version `5.0.0-rc.5` (Kubernetes `v1.36.4`), default
feature set, installed fresh at that version (a single `Completed` entry in the ClusterVersion history).
Every command was run with an explicit `--kubeconfig`. Raw output, which contains API URLs, node names and
addresses, is in the git-ignored directory `evidence/2026-10-10-olmv1-investigate/raw/` (file names are
cited below as `raw: <file>`). This note contains no cluster-identifying details. Image references are
quoted by digest prefix only. Important limitation: **no `ClusterExtension` existed on the cluster and
none was created**, so every question that needs a rendered extension (field managers, Helm release
Secret, proxy injection, owner-name label patterns, medik8s webhooks) stays open.

## Q1: Platform build (versions, images, args, gates, RBAC)

### Takeaway
OCP 5.0 rc5 ships OLM v1 as a downstream build of upstream `operator-controller` synchronized on
2026-08-12 (upstream commits through 2026-08-11), i.e. **after upstream v1.11.0 (2026-07-23) and before
v1.12.0 (2026-09-24)**. The operator-controller ServiceAccount is bound to `cluster-admin`. Gates on by
default: only `WebhookProviderOpenshiftServiceCA`. Off: `BoxcutterRuntime`, `BundleReleaseSupport`,
`DeploymentConfig`, `SingleOwnNamespaceInstallSupport`, `WebhookProviderCertManager`, catalogd
`APIV1MetasHandler` and `GraphQLCatalogQueries`. cert-manager is not installed. OLM Classic still runs.

### Observed
- `oc get clusterversion version -o jsonpath='{.status.desired.version}'` → `5.0.0-rc.5` (raw: `q1-clusterversion.txt`).
- `oc get ns | grep -i -E 'olm|catalogd|operator-controller'` → `openshift-catalogd`, `openshift-cluster-olm-operator`, `openshift-operator-controller`, plus `openshift-operator-lifecycle-manager` (raw: `q1-olm-namespaces.txt`).
- Deployments (raw: `q1-deploy-<ns>.yaml`, summaries `q1-deploy-<ns>-summary.txt`):
  - `openshift-operator-controller/operator-controller-controller-manager`: 2 replicas, single container `manager`, image `quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:ff91158d…`, command `/operator-controller`, args
    `--health-probe-bind-address=:8081 --metrics-bind-address=:8443 --leader-elect --feature-gates=WebhookProviderOpenshiftServiceCA=true --feature-gates=BoxcutterRuntime=false --feature-gates=DeploymentConfig=false --feature-gates=SingleOwnNamespaceInstallSupport=false --feature-gates=WebhookProviderCertManager=false --tls-cert=/var/certs/tls.crt --tls-key=/var/certs/tls.key --catalogd-cas-dir=/var/ca-certs --v=4 --global-pull-secret=openshift-config/pull-secret --tls-custom-version=TLSv1.2 --tls-custom-ciphers=… --tls-profile=custom`;
    env `SSL_CERT_DIR=/var/ca-certs`. There is **no `--pull-cas-dir`** flag; registry trust comes from `SSL_CERT_DIR` pointing at a projected volume of ConfigMap `operator-controller-trusted-ca-bundle` (`ca-bundle.crt`) plus `openshift-service-ca.crt` (`service-ca.crt`). hostPath mounts `/etc/containers` and `/etc/docker` (where `registries.conf` and mirror policy live). No kube-rbac-proxy sidecar. `revisionHistoryLimit: 10`.
  - `openshift-catalogd/catalogd-controller-manager`: 2 replicas, image `…@sha256:f45f0f32…`, command `./catalogd`, args `--leader-elect --metrics-bind-address=:7443 --external-address=catalogd-service.openshift-catalogd.svc --feature-gates=APIV1MetasHandler=false --tls-cert… --tls-key… --v=4 --global-pull-secret=openshift-config/pull-secret --tls-custom-version=TLSv1.2 --tls-custom-ciphers=… --tls-profile=custom`; same `SSL_CERT_DIR`, trusted-CA projection (`catalogd-trusted-ca-bundle`) and hostPath mounts.
  - `openshift-cluster-olm-operator/cluster-olm-operator`: env `OPERATOR_IMAGE_VERSION=5.0.0-rc.5`, `CATALOGD_IMAGE`, `OPERATOR_CONTROLLER_IMAGE` and `KUBE_RBAC_PROXY_IMAGE` (the last is not used by either operand pod).
- Startup logs (raw: `q1-operator-controller-log-version.txt`, `q1-catalogd-log-version.txt`): `"starting up the controller" version info="version: \"1.26\", commit: \"49582d3d…\", date: \"2026-09-29…\""`; `"feature gate status" BoxcutterRuntime=false BundleReleaseSupport=false DeploymentConfig=false SingleOwnNamespaceInstallSupport=false WebhookProviderCertManager=false WebhookProviderOpenshiftServiceCA=true`; catalogd: `APIV1MetasHandler=false GraphQLCatalogQueries=false`. Both binaries log `Warning: setting GA feature gate. It will be removed in a future release` for `WebhookProviderOpenshiftServiceCA` and `WebhookProviderCertManager`, so upstream treats both webhook providers as GA. The `version: "1.26"` string is not an upstream tag (the downstream build does not inject one); the commit is the downstream merge of PR `openshift/operator-framework-operator-controller#788` "NO-ISSUE: Synchronize From Upstream Repositories" (merged 2026-08-12, upstream commits 2026-07-29 through 2026-08-11), which dates the code between upstream v1.11.0 and v1.12.0.
- `oc get featuregate cluster` (raw: `q1-featuregate.yaml`, `q1-featuregate-summary.txt`): `spec.featureSet` is empty (Default). Enabled: `NewOLM`, `NewOLMWebhookProviderOpenshiftServiceCA`, `OLMLifecycleAndCompatibility`, `GatewayAPIWithoutOLM`. Disabled: `NewOLMBoxCutterRuntime`, `NewOLMCatalogdAPIV1Metas`, `NewOLMConfigAPI`, `NewOLMOwnSingleNamespace`.
- `oc get clusteroperator olm` (raw: `q1-clusteroperator-olm.yaml`): `Degraded=False/AsExpected`, `Progressing=False`, `Available=True`, `Upgradeable=True`, `versions: operator 5.0.0-rc.5`. The `OLM` operator CR (`olm.operator.openshift.io/cluster`, raw: `q1-olm-operator-cr.yaml`) carries `capability.openshift.io/name: OperatorLifecycleManagerV1`, `managementState: Managed` and the observed TLS security profile that becomes the `--tls-custom-*` args.
- RBAC (raw: `q1-operator-controller-rbac.txt`): ServiceAccount `operator-controller-controller-manager` is bound by ClusterRoleBinding **`operator-controller-cluster-admin-rolebinding` → ClusterRole `cluster-admin`** (plus `operator-controller-proxy-rolebinding`). catalogd's SA is bound to `catalogd-manager-role` and `catalogd-proxy-role` only.
- `oc get crd certificates.cert-manager.io` → `NotFound` (raw: `q1-certmanager-crd.txt`).
- Both OLM v1 namespaces carry a `*-default-deny-all-traffic` NetworkPolicy plus a per-manager allow policy (raw: `q1-olm-networkpolicies.txt`).

### Implications for WAO
- RBAC can no longer be proven on 5.0: operator-controller is cluster-admin, so a missing installer permission will never surface here. Prove installer RBAC on 4.18–4.22 clusters (the report's conclusion stands).
- The trusted-CA path for private catalog/bundle registries on 5.0 is the `*-trusted-ca-bundle` ConfigMap managed by cluster-olm-operator plus the node's `/etc/containers`; there is no `--pull-cas-dir` to document.
- Nothing TechPreview is needed for WAO on 5.0: Service-CA webhook support is on by default (irrelevant to WAO's bundle anyway, since the bundle has no `webhookdefinitions`).

## Q2: ClusterExtension API on 5.0 rc5

### Takeaway
`olm.operatorframework.io/v1` is the only served and storage version. `spec.required` is
`[namespace, source]`; `spec.serviceAccount` is optional, documented as "deprecated … completely ignored",
and setting it triggers a **warn-only** ValidatingAdmissionPolicy. The CRDs were generated from the
upstream *experimental* manifest set (annotation `olm.operatorframework.io/generator: experimental`), so
`spec.progressDeadlineMinutes`, `status.activeRevisions` (ClusterObjectSet revisions) and
`status.install.bundle.release` are present in the schema even though Boxcutter is disabled and no
`ClusterObjectSet`/`ClusterExtensionRevision` CRD exists. `spec.config` only knows `configType: Inline`
with free-form `inline`; there is no `watchNamespace` or `deploymentConfig` in the schema (the inline
object is validated at runtime against the bundle's schema). No CRD-retention field exists.

### Observed
- `oc get crd clusterextensions.olm.operatorframework.io -o yaml` (raw: `q2-crd-clusterextensions.yaml`, summary `q2-crd-clusterextensions-summary.txt`): one version `v1`, `served=true`, `storage=true`; annotations `controller-gen.kubebuilder.io/version`, `olm.operatorframework.io/generator: experimental`; managed by field manager `cluster-olm-operator` (raw: `q2-crd-managedfields.txt`).
- `spec.required: ['namespace', 'source']`; `spec.properties: config, install, namespace, progressDeadlineMinutes, serviceAccount, source`; `status.properties: activeRevisions, conditions, install`.
- `serviceAccount` description, verbatim: "serviceAccount is a deprecated field and is completely ignored. OLMv1 is a single-tenant system where users with ClusterExtension write access are effectively delegated cluster-admin trust. The operator-controller runs with cluster-admin privileges and uses its own service account for all cluster interactions. Deprecated: serviceAccount is no longer used and will be removed in a future release." `serviceAccount.name` keeps `minLength 1`, `maxLength 253`, CEL `self == oldSelf` ("name is immutable once set but may be cleared") and the DNS-1123 subdomain regex.
- `config`: `required: [configType]`, `configType` enum `[Inline]`, `inline` is `type: object`, `minProperties: 1`, `x-kubernetes-preserve-unknown-fields: true`; CEL "inline is required when configType is Inline, and forbidden otherwise".
- `install.preflight.crdUpgradeSafety.enforcement` enum `[None, Strict]` (required when `preflight` is set); CEL "at least one of [preflight] are required when install is specified" and "at least one of [crdUpgradeSafety] are required when preflight is specified".
- `progressDeadlineMinutes`: optional int32, min 10, max 720, "disabled when no value is provided".
- `status.install.bundle.release`: optional, max 20 chars, "for registry+v1 bundles lacking an explicit release value, this field contains the release extracted from version's build metadata (e.g., '2' from '1.0.0+2')".
- Other `x-kubernetes-validations` messages: "namespace is immutable", "namespace must be a valid DNS1123 label", "catalog is required when sourceType is Catalog, and forbidden otherwise", "channels entries must be valid DNS1123 subdomains", "packageName is immutable", "packageName must be a valid DNS1123 subdomain…", "invalid version expression" (the semver-range regex), "version must be well-formed semver" (status).
- CRDs in group `olm.operatorframework.io`: only `clustercatalogs` and `clusterextensions` (raw: `q2-crds-olm-group.txt`). `oc get clusterobjectsets -A` and `oc get clusterextensionrevisions -A` → "the server doesn't have a resource type" (raw: `q4-clusterobjectsets.txt`, `q4-clusterextensionrevisions.txt`).
- ValidatingAdmissionPolicy (raw: `q2-vap-all.yaml`, `q2-vapb-all.yaml`, summary `q2-vap-summary.txt`): `clusterextension-serviceaccount-deprecated`, `failurePolicy: Ignore`, matches `olm.operatorframework.io/v1 clusterextensions` on CREATE and UPDATE, expression `!has(object.spec.serviceAccount) || !has(object.spec.serviceAccount.name) || object.spec.serviceAccount.name == ''`, message "spec.serviceAccount is deprecated, ignored, and will be removed in a future release. The operator-controller's cluster-admin service account is used for all cluster interactions." Binding of the same name: `validationActions: [Warn]`, no `matchResources`. No other VAP mentions clusterextensions.
- Server-side dry run (raw: `q2-dryrun-manifest.yaml`, `q2-dryrun-output.txt`) of a `ClusterExtension` named `olmv1-investigate-dryrun` with `spec.namespace: default`, `spec.serviceAccount.name: nonexistent`, `packageName: nonexistent-package`; `oc apply --dry-run=server -f … 2>&1` printed, verbatim:
  ```
  Warning: Validation failed for ValidatingAdmissionPolicy 'clusterextension-serviceaccount-deprecated' with binding 'clusterextension-serviceaccount-deprecated': spec.serviceAccount is deprecated, ignored, and will be removed in a future release. The operator-controller's cluster-admin service account is used for all cluster interactions.
  clusterextension.olm.operatorframework.io/olmv1-investigate-dryrun created (server dry run)
  ```
  exit code 0; a subsequent `oc get clusterextension olmv1-investigate-dryrun` returned `NotFound`, confirming nothing was persisted. Admission did not check that the ServiceAccount or the package exists.

### Implications for WAO
- The project's ec.5 observation is confirmed on rc5: keep `spec.serviceAccount.name` in the shipped manifest for 4.18–4.22, accept one warning line on 5.0, and plan the removal as a docs change. The field stays immutable once set, so a manifest that drops it later must *clear* it rather than rename it.
- `spec.config.inline` exists on 5.0 (schema-less until a bundle ships a config schema); WAO's bundle ships none, so any `config` on a WAO ClusterExtension would be rejected at runtime, not at admission.
- `progressDeadlineMinutes` is available if WAO's install docs want a bounded "Blocked" signal.

## Q3: Catalogs and the catalogd HTTP API

### Takeaway
Three default `ClusterCatalog`s exist (`openshift-redhat-operators` -100, `openshift-certified-operators`
-200, `openshift-community-operators` -400; **no marketplace catalog on this cluster**), all `Available`,
polling every 10 minutes, tagged `:v5.0` in spec and resolved to a digest in status. catalogd serves
`/catalogs/<name>/api/v1/all` over the in-cluster Service (HTTP 200, `application/jsonl`, Range requests
honoured with 206) with no bearer token; `/api/v1/metas` returns **404** (gate off); there is no Route.
The Red Hat catalog for 5.0 carries all six RHWA packages (and no WAO package).

### Observed
- `oc get clustercatalog -o custom-columns=…` (raw: `q3-clustercatalog-columns.txt`, `q3-clustercatalog.yaml`, summary `q3-clustercatalog-summary.txt`): priorities -100/-200/-400, `availabilityMode: Available`, `pollIntervalMinutes: 10`, refs `registry.redhat.io/redhat/{redhat,certified,community}-operator-index:v5.0`. Status `resolvedSource.image.ref` is the same repository `@sha256:…` (digest form); `status.urls.base` has the form `https://catalogd-service.openshift-catalogd.svc/catalogs/<name>`; conditions `Progressing=True/Succeeded` "Successfully unpacked and stored content from resolved source" and `Serving=True/Available` "Serving desired content from resolved source". Each catalog is auto-labelled `olm.operatorframework.io/metadata.name=<name>`.
- `ClusterCatalog` CRD (raw: `q3-crd-clustercatalogs.yaml`): `spec.source.type` enum is still only `[Image]`; `availabilityMode` enum `[Unavailable, Available]`; `priority` default 0, full int32 range; `image.ref` must end with a tag or digest.
- Field managers on a ClusterCatalog (raw: `q4-clustercatalog-managedfields.txt`): `CatalogdClusterCatalogOpenshiftRedhatOperators` (Apply, from cluster-olm-operator), `catalogd` (Update) and `catalogd` (Update, subresource `status`).
- `oc get route -n openshift-catalogd` → none. Service `catalogd-service` exposes 443, 9443, 7443 (raw: `q3-catalogd-route.txt`, `q3-catalogd-svc.txt`).
- Port-forward `svc/catalogd-service 18443:443` then `curl -sk` (raw: `q3-catalogd-api-*.txt`):
  - `GET /catalogs/openshift-redhat-operators/api/v1/all` with `Range: bytes=0-299` and no token → `HTTP 206`, `content-type=application/jsonl`, body starts `{"defaultChannel":"threescale-2.13","icon":{…`. A full fetch returned `HTTP 200`, 56.8 MB. (`oc whoami -t` returned no token for the certificate-based kubeconfig, so the request was unauthenticated and still served.)
  - `GET …/api/v1/metas?schema=olm.package` → `HTTP 404`, body `404 page not found`. `GET …/api/v1/graphql` → `HTTP 404`.
- RHWA content in the 5.0 Red Hat catalog (raw: `q3-catalogd-medik8s-packages.txt`, `q3-redhat-catalog-rhwa-bundle-properties.txt`, `q3-packagemanifests-medik8s.txt`): packages `fence-agents-remediation` (0.8.0, 0.8.1), `machine-deletion-remediation` (0.7.0, 0.7.1), `node-healthcheck-operator` (0.12.0, 0.12.1), `node-maintenance-operator` (5.7.0, 5.7.1), `self-node-remediation` (0.13.0, 0.13.1), `storage-based-remediation` (0.3.0, 0.3.1); each channel `stable` with `replaces` edges and `skipRange` on every entry (except the first SBR entry); bundle images under `registry.redhat.io/workload-availability/*-operator-bundle@sha256:…`; bundles use `olm.csv.metadata` (not `olm.bundle.object`), `olm.gvk` and `olm.package` properties only, `installModes` AllNamespaces-only, `apiServiceDefinitions: {}`, and **no `olm.properties` annotation (so no `olm.maxOpenShiftVersion`)**. NHC carries `console.openshift.io/plugins`. No `workload-availability-operator` package. The same packages appear in OLM Classic `packagemanifests` from both the Red Hat and Community CatalogSources.

### Implications for WAO
- `/api/v1/all` is the only catalogd query API to rely on in tooling and docs for 5.0; `metas` and GraphQL are not reachable without a TechPreview gate.
- A WAO `ClusterCatalog` at default priority 0 still outranks every default catalog; pin the WAO ClusterExtension with `selector` as the report recommends.
- The shipped RHWA packages prove the FBC shape Red Hat uses for this product line (`olm.csv.metadata`, `replaces` + `skipRange`, digest bundle refs, no `olm.maxOpenShiftVersion`), which WAO's FBC should mirror.

## Q4: Existing extensions, OLM Classic coexistence, proxy

### Takeaway
No `ClusterExtension`, no WAO namespace, no medik8s CRDs, no `olm.operatorframework.io/owner-name`
labelled RBAC and no `helm.sh/release.v1` Secret exist anywhere, so the rendered-object questions could
not be observed. OLM Classic is fully present on 5.0 rc5 (four deployments, 457 PackageManifests, three
CatalogSources, three OperatorGroups, one CSV: `packageserver`). The cluster-wide proxy is unset, so proxy
injection would not have been observable even with an extension installed.

### Observed
- `oc get clusterextension -o yaml` → `No resources found` (raw: `q4-clusterextension.yaml`, `q4-clusterextension-list.txt`).
- `oc get ns | grep -i -E 'workload|medik8s|remediation'` → only `openshift-user-workload-monitoring`; `oc get crd | grep -i -E 'medik8s|workloadavailability'` → nothing; `oc get clusterrole,clusterrolebinding -l olm.operatorframework.io/owner-name` → nothing; `oc get secrets -A --field-selector type=helm.sh/release.v1` (names and types only) → nothing (raw: `q4-leftover-*.txt`, `q4-owner-name-labelled-rbac.txt`, `q4-helm-release-secrets.txt`).
- `oc get subscriptions.operators.coreos.com -A` → none; `oc get csv -A` → `openshift-operator-lifecycle-manager/packageserver 0.0.1-snapshot Succeeded` only; `oc get deploy -n openshift-operator-lifecycle-manager` → `catalog-operator`, `olm-operator`, `package-server-manager`, `packageserver` all available; `oc get packagemanifests -A` → 457 rows; `oc get catalogsource -A` → `certified-operators`, `community-operators`, `redhat-operators` (grpc) in `openshift-marketplace`; `oc get operatorgroups -A` → `openshift-monitoring/openshift-cluster-monitoring`, `openshift-operator-lifecycle-manager/olm-operators`, `openshift-operators/global-operators` (raw: `q4-subscriptions.txt`, `q4-csv-all.txt`, `q4-olm-classic-deploy.txt`, `q4-packagemanifests-*.txt`, `q4-catalogsource.txt`, `q4-operatorgroups.txt`).
- `oc get proxy cluster -o jsonpath='{.spec}'` → `{"trustedCA":{"name":""}}` (raw: `q4-proxy-spec.txt`).

### Implications for WAO
- Experiment 0005 (Classic six → one WAO ClusterExtension) remains valid on 5.0: Classic is present and the RHWA packages are in both Classic CatalogSources and OLM v1 ClusterCatalogs from the same index images.
- The field-manager names, Helm Secret vs. revision storage, `olm.*` labels on rendered objects and the "already exists … cannot be managed" string still need a mutating experiment (run experiment 0004's install path on this cluster when the owner approves cluster mutation).

## Q5: Webhooks on 5.0

### Takeaway
No medik8s/WAO webhook configuration exists (nothing is installed). catalogd's own
`MutatingWebhookConfiguration` demonstrates the 5.0 Service-CA pattern OLM v1 uses for itself:
`service.beta.openshift.io/inject-cabundle: "true"`, `caBundle` populated, `failurePolicy: Fail`, and the
Service annotated with `service.beta.openshift.io/serving-cert-secret-name`.

### Observed
- `oc get validatingwebhookconfigurations,mutatingwebhookconfigurations` (raw: `q5-webhook-list.txt`): 10 validating and 3 mutating configurations, none matching medik8s/remediation/maintenance/workload.
- `catalogd-mutating-webhook-configuration` (raw: `q5-catalogd-mwc.yaml`, summary `q5-catalogd-mwc-summary.txt`): annotations `olm.operatorframework.io/feature-set: experimental`, `service.beta.openshift.io/inject-cabundle: "true"`; webhook `inject-metadata-name.olm.operatorframework.io`, `failurePolicy: Fail`, `caBundle` length 1616 bytes, service `openshift-catalogd/catalogd-service` port 9443 path `/mutate-olm-operatorframework-io-v1-clustercatalog`, rules `clustercatalogs` CREATE/UPDATE.
- Service `catalogd-service` annotations include `service.beta.openshift.io/serving-cert-secret-name: catalogserver-cert`; Secret `catalogserver-cert` is `kubernetes.io/tls` (names and types only; raw: `q5-catalogd-svc-annotations.txt`, `q5-catalogd-secrets-names.txt`). `openshift-operator-controller` has `operator-controller-cert` (`kubernetes.io/tls`).

### Implications for WAO
- Nothing new: WAO's runtime-created webhooks use exactly this Service-CA pattern, and the platform's own OLM v1 components rely on it on 5.0, so there is no reason to expect the Service CA injection to change.

## Q6: Console and tooling

### Takeaway
5.0 rc5 ships no OLM v1 console plugin (only `monitoring-plugin` and `networking-console-plugin` are
registered and enabled). `oc explain clusterextension.spec.serviceAccount` prints the "deprecated …
completely ignored" text. The local `oc` client is 4.22 against server `5.0.0-rc.5`; no `opm` is on PATH.

### Observed
- `oc get consoleplugins` → `monitoring-plugin`, `networking-console-plugin`; `oc get console.operator cluster -o jsonpath='{.spec.plugins}'` → `["networking-console-plugin","monitoring-plugin"]` (raw: `q6-consoleplugins.txt`, `q6-console-plugins-spec.txt`).
- `oc explain clusterextension.spec --recursive | head -60` (raw: `q6-explain-spec-recursive.txt`): fields `config{configType (required, enum Inline), inline}`, `install.preflight.crdUpgradeSafety.enforcement (enum None, Strict)`, `namespace (required)`, `progressDeadlineMinutes`, `serviceAccount.name`, `source{catalog{channels, packageName (required), selector, upgradeConstraintPolicy (enum CatalogProvided, SelfCertified), version}, sourceType (required, enum Catalog)}`. `oc explain clusterextension.spec.serviceAccount` (raw: `q6-explain-serviceaccount.txt`) prints "serviceAccount is a deprecated field and is completely ignored … Deprecated: serviceAccount is no longer used and will be removed in a future release."
- `oc version`: client `4.22.0-…`, Kustomize `v5.7.1`, server `5.0.0-rc.5`, Kubernetes `v1.36.4` (raw: `q6-oc-version.txt`). `opm` not found (raw: `q6-opm-version.txt`).

### Implications for WAO
- OLM v1 remains CLI-only on 5.0 rc5; WAO install docs for 5.0 need `oc` steps, not console steps.
- Which `opm` version the release embeds cannot be read from the cluster; take it from the `operator-registry` image of the 5.0 payload when the FBC build is pinned.

## Open questions resolved / still open

Mapping of the report's "Open questions and gaps" paragraph to this inspection:

| Report item | Status | Observation |
| --- | --- | --- |
| Which operator-controller tag each OCP minor ships | Partly resolved | 5.0 rc5 runs a downstream sync merged 2026-08-12 (upstream commits through 2026-08-11): after v1.11.0, before v1.12.0. Gate inventory matches that window (`BundleReleaseSupport` present, `PreflightPermissions`/`SyntheticPermissions` absent). The binary's own version string (`1.26`) is not an upstream tag. |
| Which OpenShift release adopts the `spec.serviceAccount` deprecation | Resolved for 5.0 (rc5) | Field optional, documented as "deprecated … completely ignored"; warn-only VAP `clusterextension-serviceaccount-deprecated` (`validationActions: [Warn]`, `failurePolicy: Ignore`); operator-controller SA bound to `cluster-admin`. Red Hat docs statement still outstanding, but the shipped rc5 payload behaves this way. |
| Proxy variables / trusted CA injected into extension Deployments | Still open | No extension installed and cluster proxy spec is empty, so not observable here. The `DeploymentConfig` gate (the Subscription `spec.config` parity path) is off by default on 5.0. |
| Major-zero upgrade restrictions with an explicit `replaces` edge under `CatalogProvided` | Still open | Not testable read-only. Relevant because every RHWA package except NMO is major-zero and the shipped channels use `replaces` plus `skipRange`. |
| `channels` and `version` both set with nothing matching | Still open | Not testable read-only. |
| Exact "already exists … cannot be managed by operator-controller" string; server-side-apply field manager names | Still open | No rendered objects to inspect. Only catalogd-side managers seen: `catalogd` (Update, status) and the cluster-olm-operator Apply manager `CatalogdClusterCatalog<Name>`. |
| CR finalizer blocking CRD deletion during `ClusterExtension` removal | Still open | Not testable read-only. |
| CRD-retention option | Resolved (negative) | `spec` has exactly `config, install, namespace, progressDeadlineMinutes, serviceAccount, source`; no retention field. |
| catalogd and image indexes (manifest lists) | Still open | `resolvedSource` shows a digest only; whether it was an index could not be read. |
| `registries.conf` with `insecure = true` honoured | Still open (hint) | Both OLM v1 pods hostPath-mount `/etc/containers` and `/etc/docker`, which is where such a file would be read; behaviour not tested. |
| `/api/v1/metas` enabled on any OpenShift release | Resolved for 5.0 (rc5) | Disabled: `--feature-gates=APIV1MetasHandler=false`, `NewOLMCatalogdAPIV1Metas` disabled, endpoint returns 404; `/api/v1/all` served (200/206, JSONL, Range supported, unauthenticated over the Service). GraphQL also 404. |
| `opm` version embedded per release | Still open | Not readable from the cluster; no local `opm`. |
| `opm render` surfacing `olm.constraint` from `metadata/properties.yaml` | Still open | Build-side question. |
| `olm.maxOpenShiftVersion` honoured on 4.20+ | Still open (hint) | The shipped RHWA bundles in the 5.0 catalog carry no `olm.properties` annotation at all, so Red Hat ships this product line without the property. |
| OLM v1 validator / certification / KCS | Out of scope | Not a cluster question. |
| Boxcutter enablement on TechPreview clusters | Resolved for the default feature set on 5.0 (rc5) | `BoxcutterRuntime=false`, `NewOLMBoxCutterRuntime` disabled, no `ClusterObjectSet`/`ClusterExtensionRevision` CRD; but the CRDs are generated from the experimental set (`generator: experimental`), so `progressDeadlineMinutes`, `activeRevisions` and `bundle.release` appear in the schema. TechPreview behaviour not observed. |

Additional facts not in the report's list: no marketplace `ClusterCatalog` on this cluster (three, not
four, defaults); no OLM v1 console plugin on 5.0 rc5; both webhook providers are logged as GA gates
upstream; cert-manager is absent and not required.
