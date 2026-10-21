# wao_poc — Workload Availability Operator proof of concept

This repository is a **proof of concept** for consolidating the
[medik8s](https://github.com/medik8s) node remediation operators behind a single
operator, the Workload Availability Operator (WAO).

The POC installs all six upstream components as managed operands:

| Component | What it does |
| --- | --- |
| [Node Health Check (NHC)](https://github.com/medik8s/node-healthcheck-operator) | Watches node health and creates remediation requests from templates |
| [Self Node Remediation (SNR)](https://github.com/medik8s/self-node-remediation) | Remediates unhealthy nodes with per-node agents that reboot themselves |
| [Storage Based Remediation (SBR)](https://github.com/medik8s/storage-based-remediation) | Remediates nodes through shared-storage messaging and per-node agents |
| [Fence Agents Remediation (FAR)](https://github.com/medik8s/fence-agents-remediation) | Remediates nodes by running fence agents against their management interfaces |
| [Machine Deletion Remediation (MDR)](https://github.com/medik8s/machine-deletion-remediation) | Remediates nodes by deleting their Machine so the Machine API replaces it |
| [Node Maintenance (NMO)](https://github.com/medik8s/node-maintenance-operator) | Cordons and drains a node on explicit request |

The selected component tags, pull references and embedded commits are in
[release-set.yaml](release-set.yaml). Each image has a `pullRef`: `latest` uses the
floating `:latest` tag; every other tag uses a pinned digest. WAO deploys these
references, including those passed to operands for their agents. For latest, the
recorded commit identifies the vendored manifest snapshot; future image pulls can
run newer code. Refresh operands again to synchronize that snapshot. Latest operand
Deployment containers explicitly use `imagePullPolicy: Always`, which checks the
registry at startup; moving the tag does not restart running containers. Agent pod
pull policies remain controlled by the upstream operands.

## The main idea

Today each component is a separate OLM package with its own CSV, its own API
ownership and its own upgrade lifecycle. WAO replaces that with **one OLM package
that owns all the component APIs** plus a cluster-scoped `WorkloadAvailabilityConfig`
named `cluster`. A lifecycle controller installs each component's unchanged
controller-manager as a separate operand when an administrator enables it. Every
component starts **Disabled**. 

```sh
❯ oc get workloadavailabilityconfig -o yaml
apiVersion: v1
items:
- apiVersion: workloadavailability.medik8s.io/v1alpha1
  kind: WorkloadAvailabilityConfig
  metadata:
    name: cluster
  ...
  spec:
    components:
      fenceAgentsRemediation:
        state: Disabled
      machineDeletionRemediation:
        state: Disabled
      nodeHealthCheck:
        state: Disabled
      nodeMaintenance:
        state: Disabled
      selfNodeRemediation:
        state: Disabled
      storageBasedRemediation:
        state: Disabled
    ...
```
This operator does NOT intend to change the behavior or functionality of the underlying components.  Success for this operator is to simplify the publishing of the operands as a single entity.  Allow development to continue to happen in their respective repositories, sync the updated bundle artifacts of each component into this repository and publish a single operator from this repository.


## Layout

| Path | Contents |
| --- | --- |
| `release-set.yaml` | The upstream tags, commits and image pull references the POC installs |
| `api/v1alpha1/` | The `WorkloadAvailabilityConfig` API |
| `internal/controller/` | The lifecycle controller and the default-config bootstrap |
| `internal/operands/` | The embedded runtime manifests and the renderer |
| `config/operands/<k>/` | Per operand: `vendored/` (copy of the operand's `config/` tree), `VENDORED.yaml` (source and commit), `rbac/` and `runtime/` kustomize overlays |
| `hack/update-release-set.sh`, `hack/image-commit.sh` | Record floating latest or pinned release references and embedded image commits |
| `hack/update-operand-manifests.sh`, `hack/verify-operand-manifests.sh` | Copy the upstream trees at the recorded commits; offline CI verification |
| `bundle/` | The generated OLM bundle (one CSV, thirteen CRDs, twenty-one standalone ClusterRoles, and the SBR agent's ServiceAccount and ClusterRoleBinding) |
| `config/catalog/`, `catalog/` | Committed CatalogSource and Subscription templates; the rendered file-based catalog |

## Operand manifests

Each operand has a copy of its own `config/` tree in `config/operands/<k>/vendored/`, plus
two kustomize overlays: `rbac/` (rendered into the WAO CSV and bundle) and `runtime/` (rendered
into `internal/operands/manifests/<k>/objects.yaml`, the Deployments, Services, ConfigMaps and
webhook configurations the renderer applies at enable time). The operand CRDs ship in the CSV.
Never hand-edit the generated files; run `make operand-manifests`. This also generates
`internal/components/zz_generated.images.go` from `release-set.yaml`, keeping the renderer's
image bindings synchronized with the selected tags. `make verify-operand-manifests` compares
files before and after regeneration, so it works with uncommitted updates. It checks the
bundle's shape but not that it is current: `make test` checks that (via
`verify-no-changes`), or run `VERIFY_BUNDLE=1 make verify-operand-manifests`, which regenerates it
with `make bundle-reset`.

### Approach to updating operand manifests is inspired from OADP

OADP has been successfully following a similar pattern of 1 published operator that manages other operands.
We can look at how they handle the "update-*" targets in their (Makefile)[https://github.com/openshift/oadp-operator/blob/oadp-dev/Makefile]

Operand manifests are copied from each operand checkout, following OADP's non-admin-controller
pattern.
- `make update-release-set` records the selected tags, pull references and embedded
commits into `release-set.yaml`. It defaults to latest; other tags resolve to digests.
- `make update-operand-manifests` copies `config/` from a checkout at that commit into `config/operands/<k>/vendored/` (checkouts live in `.cache/operands`, or set `NHC_PATH` and friends), renders the runtime manifests the Go renderer embeds, generates Go image bindings, and syncs `RELATED_IMAGE_*`.
- Use `make bump-operands` for the complete sequence: resolve published images, copy
configuration, generate manifests and bindings, then verify consistency. 
    - `OPERAND_TAG` defaults to `latest`, the post-submit main build; pass `OPERAND_TAG=release` for each component's latest GitHub release,
    - `OPERAND_TAG=pinned` to keep the current tags while refreshing references and commits
      (latest still floats), or override one component with `NHC_TAG=...`. Operand releases can lag files the `config/operands` wrappers rely on.


## Development

### Developer install follows `make dev-olm-deploy` from shared medik8s/tools

#### Deploy the code as-is from the repository to your local cluster
```sh
# Rebuild the manager and bundle, push images, and reinstall on
# your development OpenShift cluster.
KUBECONFIG=/path/to/disposable.kubeconfig \
  make dev-olm-deploy DEV_CLUSTER_TYPE=external. # DEV_CLUSTER_TYPE=external is optional, helps to avoid confusion if you also had a kind cluster available
```

#### Rebuild the manager and wao's manifests and then deploy to your local cluster 
```sh
make generate manifests fmt # Only needed if you changed local code or manifests
KUBECONFIG=/path/to/disposable.kubeconfig \
  make dev-olm-deploy DEV_CLUSTER_TYPE=external. # DEV_CLUSTER_TYPE=external is optional, helps to avoid confusion if you also had a kind cluster available
```
  * If you changed operand manifest inputs, also run `make operand-manifests` before deploying, so the new manifests are embedded in the manager binary.

#### Update the operands and do a full rebuild and deploy to your local cluster
If you want to refresh the `release-set.yaml`, run:
```sh

# Refresh all operands from their published "latest" images.
# Record image pull references and source commits, vendor configuration,
# regenerate operand manifests/bindings, and verify consistency.
make bump-operands

# If you edited WAO source, regenerate code/manifests and format it.
make generate manifests fmt

# Rebuild the manager and bundle, push images, and reinstall on
# your development OpenShift cluster.
KUBECONFIG=/path/to/disposable.kubeconfig \
  make dev-olm-deploy DEV_CLUSTER_TYPE=external. # DEV_CLUSTER_TYPE=external is optional, helps to avoid confusion if you also had a kind cluster available

```

### Uninstall the dev installation`make dev-olm-undeploy`
```sh
make dev-olm-undeploy
```

### Running tests
The current tests are simple Go unit and envtest suites, we do not have any e2e tests implemented.

If you want to run tests, run:
```sh
make test                     # Go unit and envtest suites
make test-offline             # verify-operand-manifests plus the operand pipeline regression tests (no cluster)
```

GitHub Actions runs the Go suites, lint, `make verify-operand-manifests` and the offline tests.

## What Enabled and Disabled mean

**Enabled** applies the component's operand objects with server-side apply: the
manager Deployment, Services, ConfigMaps and webhook configurations, rendered from the
vendored `config/default` copy (the `objects.yaml` embedded in the binary) with the selected
image pull references substituted. The operand ServiceAccounts, Roles and bindings are not part of
this: OLM creates them from the WAO CSV at install, and they exist whether or not the
component is Enabled. The phase becomes
`Available` once the managers are ready and, for NHC, SNR, FAR and NMO, the
service-ca CA bundles are injected into the webhooks.

**Disabled** (the default for every component) means WAO has not created, or has
removed, the operand objects it renders (not the OLM-owned RBAC). Specifically:

- Installing WAO creates no remediation policy, remediation request, native config,
  node agent, operand Deployment or webhook configuration. The CRDs are installed
  regardless, because the CSV owns them (D8).
- Disabling removes the component's webhook configurations along with the manager. A `Fail` webhook without a backend would block even deleting the component's objects, and WAO never switches a webhook to `Ignore`. While a component is disabled its objects are not validated.
- Disable is **manager-level**. It does **not** stop what the component created
  itself: SNR's agent DaemonSet, default config, template and certificate Secret
  stay, as would SBR's agents and storage objects. WAO reports this as phase
  `DisableIncomplete` with the objects listed in `retainedResources`.
- Native objects that a disabled manager would reconcile are stranded: an active
  `NodeMaintenance` keeps its node cordoned, and FAR, MDR, SNR and SBR remediation
  objects keep their finalizers. Disable a component only when it has no active
  work.
- Objects the upstream managers create at runtime (NHC's aggregation ClusterRole,
  ConsolePlugin and the `medik8s-leases` namespace) are left behind by upstream,
  not by WAO. WAO never adopts or deletes objects it did not create.

## Uninstall

1. Set every component to `Disabled` and wait for each phase to be `Disabled` or
   `DisableIncomplete`.
2. Delete the config: `oc delete workloadavailabilityconfig cluster`. Its finalizer
   removes any remaining operand objects. WAO creates a new all-Disabled config the
   next time it starts (D4), which is harmless.
3. Delete the Subscription and the CSV in `openshift-workload-availability`.

## Security notes

- Operand RBAC is not created by WAO. It ships in the WAO CSV (operand ServiceAccount
  permissions, via `--extra-service-accounts`) and as twenty-one standalone ClusterRoles in the
  bundle, and OLM creates it at install. Six operand ServiceAccounts are folded into the CSV; the
  SBR agent's RBAC (ServiceAccount `sbr-operator-sbr-agent`, ClusterRoles
  `sbr-operator-sbr-agent-role` and `sbr-operator-sbr-agent-privileged-scc`, and a
  ClusterRoleBinding) ships as standalone bundle objects instead, because the SBR manager creates
  ClusterRoleBindings to those two ClusterRoles by name at runtime and a folded role would get an
  OLM-generated name. The operand ServiceAccounts and roles therefore exist
  from install onward, even while every component is Disabled. WAO's own role holds no union of
  operand rules. The operand rules include:
  - SCC `use` on `privileged`, because the SNR and SBR CSVs grant it for their agents;
  - NMO's `oauth.openshift.io` wildcard;
  - cluster-wide `clusterroles` and `clusterrolebindings` management from NHC and SBR.
- For the `AllNamespaces` OperatorGroup, OLM promotes each CSV's namespaced `permissions`
  to cluster-wide roles and appends get/list/watch on `namespaces`. For FAR this means its
  manager can read Secrets (fence credentials) in every namespace, which upstream FAR requires.
- Enabling SNR starts privileged node agents on every eligible node.

## License

Apache License 2.0; see [LICENSE](LICENSE).
