# Operand reference

Facts the implementation relies on, taken from the published upstream bundles
pinned in [release-set.yaml](../release-set.yaml) and from upstream source at the
matching release tags. `hack/extract-operand-manifests.py` reproduces the bundle
facts mechanically; this page exists for orientation and review.

All six CSVs support only the `AllNamespaces` install mode and suggest the
namespace `openshift-workload-availability`. None declares a conversion webhook.
Because the OperatorGroup for that mode targets all namespaces, OLM grants each CSV's
namespaced `permissions` twice: as a Role and RoleBinding in the install namespace, and
as a ClusterRole and ClusterRoleBinding with the same rules for the same ServiceAccount
(OperatorGroup controller, `ensureSingletonRBAC`). OLM appends one rule to that
ClusterRole: get, list and watch on core `namespaces`. WAO renders both, including the
appended rule. It names the
cluster-wide copy `<serviceaccount>-all-namespaces` so that it cannot collide with the
`clusterPermissions` ClusterRole, which is named after the ServiceAccount. FAR depends on
this copy because its manager lists Secrets in every namespace. NMO depends on the
appended namespaces rule: it reads the `medik8s-leases` Namespace through a cached
client, which needs list and watch, and without the rule its cache never syncs and the
manager exits every few minutes.
Every CRD has a single served and stored version: `v1beta1` for NMO's
`NodeMaintenance`, `v1alpha1` for all others. Leader-election IDs are distinct:
`e1f13584.medik8s.io` (NHC), `547f6cb6.medik8s.io` (SNR),
`sbr-operator-leader-election` (SBR), `cb305759.medik8s.io` (FAR),
`285d4098.example.com` (MDR) and `135b1886.medik8s.io` (NMO).

## Node Health Check v0.12.0

Bundle CSV `node-healthcheck-operator.v0.12.0`. Source tag commit
`a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`.

| Object | Name | Notes |
| --- | --- | --- |
| CRD | `nodehealthchecks.remediation.medik8s.io` | Cluster-scoped |
| Deployment | `node-healthcheck-controller-manager` | 2 replicas; service account `node-healthcheck-controller-manager`; image `quay.io/medik8s/node-healthcheck-operator:v0.12.0`; args `--health-probe-bind-address=:8081 --metrics-bind-address=0.0.0.0:8443 --leader-elect --enable-http2=false`; env `DEPLOYMENT_NAMESPACE` and `POD_NAME` from the downward API; selector `app.kubernetes.io/component=controller-manager, app.kubernetes.io/name=node-healthcheck-operator`; control-plane tolerations; no volumes |
| Service | `node-healthcheck-controller-manager-metrics-service` | 8443 to `https` |
| Service | `node-healthcheck-webhook-service` | 443 to 9443; WAO adds a service-ca serving-cert annotation (design brief D1) |
| ClusterRole | `node-healthcheck-metrics-reader` | `/metrics` get |
| CSV namespaced permissions | `node-healthcheck-controller-manager` | configmaps, leases, events |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `node-healthcheck-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `node-healthcheck-controller-manager`; see below |
| CSV cluster permissions | `node-healthcheck-controller-manager` | 17 rules: namespaces create/get/patch; nodes and pods read; deployments and replicasets read; OpenShift config read; consoleplugins; leases; machinehealthchecks and machines; servicemonitors; PodDisruptionBudgets read; clusterroles and clusterrolebindings `*`; nodehealthchecks; tokenreviews; subjectaccessreviews |
| ValidatingWebhookConfiguration | `node-healthcheck-validating-webhook-configuration` | Holds the webhook below; WAO adds the service-ca CA-bundle injection annotation (D1) |
| Webhook | `vnodehealthcheck.kb.io` | Validating, `Fail`, CREATE/UPDATE/DELETE on `nodehealthchecks`, path `/validate-remediation-medik8s-io-v1alpha1-nodehealthcheck` |

Created by the NHC manager at runtime, not by WAO:

| Object | Name | Source |
| --- | --- | --- |
| ClusterRole and ClusterRoleBinding | `node-healthcheck-operator-aggregation` | [rbac/aggregation.go](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/rbac/aggregation.go) |
| ConsolePlugin (OpenShift only) | `node-remediation-console-plugin`, pointing at Service `node-healthcheck-node-remediation-console-plugin`, which the upstream bundle does not ship | [console/plugin.go](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/console/plugin.go) |
| ServiceMonitor (OpenShift only) | `node-healthcheck-controller-manager-metrics-monitor`, referencing CA ConfigMap `node-healthcheck-ca-bundle` | [servicemonitor/monitor.go](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/servicemonitor/monitor.go) |
| Namespace | `medik8s-leases` (or `LEASE_NAMESPACE`), created on first node lease | medik8s common lease manager, vendored |

Admission behavior useful for tests: the webhook rejects a policy that sets both
`minHealthy` and `maxUnhealthy`, with the message "minHealthy and maxUnhealthy
cannot be specified at the same time". The CRD has no CEL rule for this, so the
rejection proves the webhook is reachable. The webhook also rejects every policy on
an unsupported control-plane topology; OpenShift's `HighlyAvailable`,
`SingleReplica`, `HighlyAvailableArbiter` and `External` topologies are
supported ([cluster/capabilities.go](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/cluster/capabilities.go)).

## Self Node Remediation v0.13.0

Bundle CSV `self-node-remediation.v0.13.0`. Source tag commit
`79fb792830c6db78b0dab45c45f5b79591118c76`.

| Object | Name | Notes |
| --- | --- | --- |
| CRDs | `selfnoderemediationconfigs`, `selfnoderemediations`, `selfnoderemediationtemplates` in group `self-node-remediation.medik8s.io` | Namespaced |
| Deployment | `self-node-remediation-controller-manager` | 2 replicas; service account `self-node-remediation-controller-manager`; image `quay.io/medik8s/self-node-remediation-operator:v0.13.0`; args `--health-probe-bind-address=:8081 --metrics-bind-address=:8443 --leader-elect --is-manager --enable-http2=false`; env `MY_NODE_NAME` and `DEPLOYMENT_NAMESPACE` from the downward API, `SELF_NODE_REMEDIATION_IMAGE` (the agent image, equal to the manager image); ports 9443 `webhook-server` and 8443 `https`; `runAsUser: 65532`; selector `control-plane=controller-manager, self-node-remediation-operator=""` |
| Service | `self-node-remediation-controller-manager-metrics-service` | 8443 to `https` |
| Service | `self-node-remediation-webhook-service` | 443 to 9443; WAO adds a service-ca serving-cert annotation |
| ConfigMap | `self-node-remediation-manager-config` | Legacy controller-manager config |
| ClusterRoles | `self-node-remediation-ext-remediation`, `self-node-remediation-metrics-reader` | |
| CSV namespaced permissions | `self-node-remediation-controller-manager` | configmaps, leases, events |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `self-node-remediation-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `self-node-remediation-controller-manager`; see below |
| CSV cluster permissions | `self-node-remediation-controller-manager` | 14 rules: namespaces read; nodes and secrets full; pods delete and read; daemonsets full; machines full; SCC `privileged` use; SNR resources full; volumeattachments; tokenreviews; subjectaccessreviews |
| Webhook configurations | `self-node-remediation-mutating-webhook-configuration`, `self-node-remediation-validating-webhook-configuration` | Hold the webhooks below; WAO adds the service-ca CA-bundle injection annotation (D1) |
| Webhooks | `mselfnoderemediationtemplate.kb.io` | Mutating, `Fail`, CREATE/UPDATE templates; adds annotation `remediation.medik8s.io/multiple-templates-support: "true"` |
| | `vselfnoderemediation.kb.io` | Validating, **`Ignore`**, CREATE/UPDATE remediations |
| | `vselfnoderemediationconfig.kb.io` | Validating, `Fail`, CREATE/UPDATE/DELETE configs |
| | `vselfnoderemediationtemplate.kb.io` | Validating, `Fail`, CREATE/UPDATE templates |

Created by the SNR manager at runtime, not by WAO:

| Object | Name | Source |
| --- | --- | --- |
| SelfNodeRemediationConfig | `self-node-remediation-config` in the deployment namespace, created at startup if absent | [configinitializer.go](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/snrconfighelper/configinitializer.go) |
| SelfNodeRemediationTemplate | `self-node-remediation-automatic-strategy-template`, created about 10 seconds after startup if absent | [template/creator.go](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/template/creator.go) |
| Secret | `self-node-remediation-certificates`, peer TLS material | [certificates/storage.go](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/certificates/storage.go) |
| DaemonSet | `self-node-remediation-ds`, owned by the config; one privileged agent per eligible node | [config controller](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/controller/selfnoderemediationconfig_controller.go), [install/self-node-remediation-deamonset.yaml](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/install/self-node-remediation-deamonset.yaml) |

Admission behavior useful for tests: the config webhook rejects any
`SelfNodeRemediationConfig` not named `self-node-remediation-config`
("to enforce only one SelfNodeRemediationConfig in the cluster…"). A server
dry-run create of a template returns the object with the multiple-templates
annotation added, which proves the mutating webhook is reachable.

## Storage Based Remediation v0.3.0

Bundle CSV `storage-based-remediation.v0.3.0`. Source tag commit
`3d76c00102d28327b8ca7e31ea68dd915c9526a4`.

| Object | Name | Notes |
| --- | --- | --- |
| CRDs | `storagebasedremediationconfigs`, `storagebasedremediations`, `storagebasedremediationtemplates` in group `storage-based-remediation.medik8s.io` | Namespaced |
| Deployment | `sbr-operator-controller-manager` | 2 replicas; service account `sbr-operator-controller-manager`; image `quay.io/medik8s/storage-based-remediation-operator:v0.3.0`; args `--metrics-bind-address=:8443 --leader-elect --health-probe-bind-address=:8081 --enable-webhooks=false`; env `POD_NAME`, `POD_NAMESPACE`, `RELATED_IMAGE_AGENT=quay.io/medik8s/storage-based-remediation-agent:v0.3.0`; limits 500m CPU, 128Mi memory; selector `app.kubernetes.io/name=sbr-operator, control-plane=controller-manager` |
| Service | `sbr-operator-controller-manager-metrics-service` | 8443 to 8443 |
| ServiceAccount | `sbr-operator-sbr-agent` | |
| ClusterRoles | `sbr-operator-ext-remediation`, `sbr-operator-metrics-reader`, `sbr-operator-sbr-agent-privileged-scc`, `sbr-operator-sbr-agent-role`, and `sbr-operator-<kind>-admin-role`, `-editor-role` and `-viewer-role` for each of `storagebasedremediation`, `storagebasedremediationconfig` and `storagebasedremediationtemplate` | |
| ClusterRoleBinding | `sbr-operator-sbr-agent-rolebinding` | Subject namespace is the placeholder `sbr-operator-system`; WAO rewrites it (D9) |
| CSV namespaced permissions | `sbr-operator-controller-manager` | configmaps, leases, events |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `sbr-operator-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `sbr-operator-controller-manager`; see below |
| CSV cluster permissions | `sbr-operator-controller-manager` | 17 rules including nodes and nodes/status, PVCs, service accounts, daemonsets, jobs, leases, clusterroles and clusterrolebindings, SCC read/patch and `privileged` use, SBR resources, storageclasses read |
| Webhooks | none | The manager runs with `--enable-webhooks=false` |

Created by the SBR manager only after an administrator creates a
`StorageBasedRemediationConfig`, which the POC tests never do:

| Object | Name | Source |
| --- | --- | --- |
| ServiceAccount | `sbr-agent` in the config namespace | [config controller](https://github.com/medik8s/storage-based-remediation/blob/3d76c00102d28327b8ca7e31ea68dd915c9526a4/internal/controller/storagebasedremediationconfig_controller.go) |
| ClusterRoleBindings | `sbr-agent-<namespace>-<config>`, `sbr-operator-sbr-agent-privileged-scc-<namespace>` | same |
| PVC and Jobs | storage and device initialization, owned by the config | same |
| DaemonSet | agent DaemonSet owned by the config | same |

## Fence Agents Remediation v0.8.0

Bundle CSV `fence-agents-remediation.v0.8.0`. Source tag commit
`78139f2f3c2e2611863ae3bce25ac5b375d78d97`.

| Object | Name | Notes |
| --- | --- | --- |
| CRDs | `fenceagentsremediations`, `fenceagentsremediationtemplates` in group `fence-agents-remediation.medik8s.io` | Namespaced |
| Deployment | `fence-agents-remediation-controller-manager` | 2 replicas; service account `fence-agents-remediation-controller-manager`; image `quay.io/medik8s/fence-agents-remediation-operator:v0.8.0` (contains the fence agent binaries); args `--health-probe-bind-address=:8081 --metrics-bind-address=:8443 --leader-elect --enable-http2=false`; env `DEPLOYMENT_NAMESPACE`; limits 500m CPU, 512Mi memory; selector `app.kubernetes.io/name=fence-agents-remediation-operator, control-plane=controller-manager` |
| Service | `fence-agents-remediation-controller-manager-metrics-service` | 8443 to `https` |
| Service | `fence-agents-remediation-webhook-service` | 443 to 9443; WAO adds a service-ca serving-cert annotation |
| ConfigMap | `fence-agents-remediation-manager-config` | Legacy controller-manager config |
| ClusterRoles | `fence-agents-remediation-ext-remediation`, `fence-agents-remediation-metrics-reader` | |
| CSV namespaced permissions | `fence-agents-remediation-controller-manager` | configmaps, leases, events, and Secrets read (fence credentials) |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `fence-agents-remediation-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `fence-agents-remediation-controller-manager`; see below |
| CSV cluster permissions | `fence-agents-remediation-controller-manager` | 10 rules: namespaces read; nodes; pods delete and `pods/exec` create; FAR resources; volumeattachments; tokenreviews; subjectaccessreviews |
| Webhook configurations | `fence-agents-remediation-mutating-webhook-configuration`, `fence-agents-remediation-validating-webhook-configuration` | Hold the webhooks below; WAO adds the service-ca CA-bundle injection annotation (D1) |
| Webhooks | `mfenceagentsremediation.kb.io`, `mfenceagentsremediationtemplate.kb.io` | Mutating, `Fail`, CREATE/UPDATE; the template mutator adds `remediation.medik8s.io/multiple-templates-support: "true"` |
| | `vfenceagentsremediation.kb.io`, `vfenceagentsremediationtemplate.kb.io` | Validating, `Fail`, CREATE/UPDATE |

FAR creates nothing at startup. Admission behavior useful for tests: the validator
rejects an agent name with no matching binary under `/usr/sbin` in the manager image
("unsupported fence agent: …"), see
[fenceagentsremediation_params.go](https://github.com/medik8s/fence-agents-remediation/blob/78139f2f3c2e2611863ae3bce25ac5b375d78d97/api/v1alpha1/fenceagentsremediation_params.go)
and [validation.go](https://github.com/medik8s/fence-agents-remediation/blob/78139f2f3c2e2611863ae3bce25ac5b375d78d97/pkg/validation/validation.go).

## Machine Deletion Remediation v0.7.0

Bundle CSV `machine-deletion-remediation.v0.7.0`. Source tag commit
`39beef663ae7db0edd7d472362bbe445729e548d`.

| Object | Name | Notes |
| --- | --- | --- |
| CRDs | `machinedeletionremediations`, `machinedeletionremediationtemplates` in group `machine-deletion-remediation.medik8s.io` | Namespaced |
| Deployment | `machine-deletion-remediation-controller-manager` | 1 replica; service account `machine-deletion-remediation-controller-manager`; image `quay.io/medik8s/machine-deletion-remediation-operator:v0.7.0`; args `--health-probe-bind-address=:8081 --metrics-bind-address=:8443 --leader-elect`; no env; limits 100m CPU, 30Mi memory; selector **`control-plane=controller-manager` only** |
| Service | `machine-deletion-remediation-controller-manager-metrics-service` | 8443 to `https`; upstream selector `control-plane: controller-manager`, which also matches the FAR, NMO, SBR and SNR manager pods. WAO narrows it (design brief D10) |
| ConfigMap | `machine-deletion-remediation-manager-config` | Legacy controller-manager config |
| ClusterRoles | `machine-deletion-remediation-machine-deletion-remediation-ext-remediation`, `machine-deletion-remediation-metrics-reader` | |
| CSV namespaced permissions | `machine-deletion-remediation-controller-manager` | configmaps, leases, events |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `machine-deletion-remediation-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `machine-deletion-remediation-controller-manager`; see below |
| CSV cluster permissions | `machine-deletion-remediation-controller-manager` | 8 rules: nodes read; MDR resources; machinesets and controlplanemachinesets read; machines full; tokenreviews; subjectaccessreviews |
| Webhooks | none | |

MDR acts through the OpenShift Machine API (`machine.openshift.io`)
([main.go](https://github.com/medik8s/machine-deletion-remediation/blob/39beef663ae7db0edd7d472362bbe445729e548d/cmd/main.go)). It creates nothing at startup.

## Node Maintenance v0.21.0

Bundle CSV `node-maintenance-operator.v0.21.0`. Source tag commit
`3a54cd157723cd555ebd792c52e8d363d9df6dd3`.

| Object | Name | Notes |
| --- | --- | --- |
| CRD | `nodemaintenances.nodemaintenance.medik8s.io` | Cluster-scoped, `v1beta1` |
| Deployment | `node-maintenance-operator-controller-manager` | 1 replica; service account `node-maintenance-operator-controller-manager`; image `quay.io/medik8s/node-maintenance-operator:v0.21.0`; args `--health-probe-bind-address=:8081 --metrics-bind-address=:8443 --leader-elect --enable-http2=false`; env `OPERATOR_NAMESPACE`; ports 9443 `webhook-server` and 8443 `https`; selector `control-plane=controller-manager, node-maintenance-operator=""` |
| Service | `node-maintenance-operator-controller-manager-metrics-service` | 8443 to `https` |
| Service | `node-maintenance-operator-webhook-service` | 443 to 9443; WAO adds a service-ca serving-cert annotation |
| ClusterRole | `node-maintenance-operator-metrics-reader` | |
| CSV namespaced permissions | `node-maintenance-operator-controller-manager` | configmaps, leases, events |
| OLM all-namespaces copy | ClusterRole and ClusterRoleBinding `node-maintenance-operator-controller-manager-all-namespaces` | Same rules as the namespaced permissions plus get/list/watch on `namespaces`, bound to `node-maintenance-operator-controller-manager`; see below |
| CSV cluster permissions | `node-maintenance-operator-controller-manager` | 14 rules including namespaces create/get; nodes; pods and `pods/eviction`; workload controllers read; leases; servicemonitors; NodeMaintenance resources; `oauth.openshift.io` `*`; PodDisruptionBudgets read |
| ValidatingWebhookConfiguration | `node-maintenance-operator-validating-webhook-configuration` | Holds the webhook below; WAO adds the service-ca CA-bundle injection annotation (D1) |
| Webhook | `vnodemaintenance.kb.io` | Validating, `Fail`, CREATE/UPDATE `nodemaintenances` |

NMO uses the same medik8s node-lease library as NHC, with lease namespace
`LEASE_NAMESPACE` or the default `medik8s-leases`
([main.go](https://github.com/medik8s/node-maintenance-operator/blob/3a54cd157723cd555ebd792c52e8d363d9df6dd3/cmd/main.go)). Admission behavior useful for tests: the validator
rejects a `NodeMaintenance` whose node does not exist ("invalid nodeName, no node with
name … found"), see
[nodemaintenance_webhook.go](https://github.com/medik8s/node-maintenance-operator/blob/3a54cd157723cd555ebd792c52e8d363d9df6dd3/internal/webhook/v1beta1/nodemaintenance_webhook.go).
Creating a real `NodeMaintenance` cordons and drains the node.

## Images

| Variable | Upstream reference in the bundle | Used for |
| --- | --- | --- |
| `RELATED_IMAGE_NHC_MANAGER` | `quay.io/medik8s/node-healthcheck-operator:v0.12.0` | NHC manager |
| `RELATED_IMAGE_SNR_MANAGER` | `quay.io/medik8s/self-node-remediation-operator:v0.13.0` | SNR manager and, through `SELF_NODE_REMEDIATION_IMAGE`, its agents |
| `RELATED_IMAGE_SBR_MANAGER` | `quay.io/medik8s/storage-based-remediation-operator:v0.3.0` | SBR manager |
| `RELATED_IMAGE_SBR_AGENT` | `quay.io/medik8s/storage-based-remediation-agent:v0.3.0` | SBR agents, through `RELATED_IMAGE_AGENT` |
| `RELATED_IMAGE_FAR_MANAGER` | `quay.io/medik8s/fence-agents-remediation-operator:v0.8.0` | FAR manager |
| `RELATED_IMAGE_MDR_MANAGER` | `quay.io/medik8s/machine-deletion-remediation-operator:v0.7.0` | MDR manager |
| `RELATED_IMAGE_NMO_MANAGER` | `quay.io/medik8s/node-maintenance-operator:v0.21.0` | NMO manager |

The bundles reference tags. WAO renders the pinned digests from
`release-set.yaml` instead, so a moved tag cannot change what is installed. All seven
images are single-architecture `linux/amd64` at these releases.
