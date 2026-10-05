# wao_poc — Workload Availability Operator proof of concept

This repository is a **proof of concept** for consolidating the
[medik8s](https://github.com/medik8s) node remediation operators behind a single
operator, the Workload Availability Operator (WAO). It exists to test an approach.
It is not a supported product, not a migration tool and not the final design.

The POC installs all six upstream components as managed operands:

| Component | Upstream release | What it does |
| --- | --- | --- |
| Node Health Check (NHC) | [v0.12.0](https://github.com/medik8s/node-healthcheck-operator/releases/tag/v0.12.0) | Watches node health and creates remediation requests from templates |
| Self Node Remediation (SNR) | [v0.13.0](https://github.com/medik8s/self-node-remediation/releases/tag/v0.13.0) | Remediates unhealthy nodes with per-node agents that reboot themselves |
| Storage Based Remediation (SBR) | [v0.3.0](https://github.com/medik8s/storage-based-remediation/releases/tag/v0.3.0) | Remediates nodes through shared-storage messaging and per-node agents |
| Fence Agents Remediation (FAR) | [v0.8.0](https://github.com/medik8s/fence-agents-remediation/releases/tag/v0.8.0) | Remediates nodes by running fence agents against their management interfaces |
| Machine Deletion Remediation (MDR) | [v0.7.0](https://github.com/medik8s/machine-deletion-remediation/releases/tag/v0.7.0) | Remediates nodes by deleting their Machine so the Machine API replaces it |
| Node Maintenance (NMO) | [v0.21.0](https://github.com/medik8s/node-maintenance-operator/releases/tag/v0.21.0) | Cordons and drains a node on explicit request |

## The idea in one paragraph

Today each component is a separate OLM package with its own CSV, its own API
ownership and its own upgrade lifecycle. WAO replaces that with **one OLM package
that owns all the component APIs** plus a cluster-scoped `WorkloadAvailabilityConfig`
named `cluster`. A lifecycle controller installs each component's unchanged
controller-manager as a separate operand when an administrator enables it. Every
component starts **Disabled**. See [docs/design-brief.md](docs/design-brief.md).

## Status

| Step | State |
| --- | --- |
| Design brief | Written |
| Implementation plan for the install case | Written: [docs/implementation-plan.md](docs/implementation-plan.md) |
| Implementation | Done: Tasks 1–10 (operator, operand manifests, bundle, image, POC catalog, live-cluster harness, docs) |
| Live install verification | Run on a disposable OpenShift 4.22 cluster (3 nodes, `HighlyAvailable`): four full runs of 19 cases. Runs found two WAO RBAC bugs, both fixed (see [Deviations from the plan](#deviations-from-the-plan), items 3 and 8). The final run passed 17 of 19: WAO-INST-09 and WAO-INST-12 failed only because the upstream MDR manager could not start under its 30Mi memory limit, which reproduces without WAO (see [Known upstream issues](#known-upstream-issues)). Every other case passed. A fifth run on 2026-10-05 against a fresh OpenShift 5.0.0-rc.5 cluster (3 nodes, `HighlyAvailable`, classic OLM) through `test/cluster/full-run.sh` passed all 19 cases, including MDR, which started with a warm page cache that time. Raw results are not committed |
| Upgrade scenarios | Future plan |

## Layout

| Path | Contents |
| --- | --- |
| `docs/design-brief.md` | Approach, decisions D1–D10 and non-goals |
| `docs/operands.md` | Facts about each upstream operand, derived from its published bundle |
| `docs/implementation-plan.md` | Task-by-task plan with tests, written for a coding agent |
| `release-set.yaml` | The pinned upstream bundle and image digests the POC installs |
| `api/v1alpha1/` | The `WorkloadAvailabilityConfig` API |
| `internal/controller/` | The lifecycle controller and the default-config bootstrap |
| `internal/operands/` | The embedded operand manifests and the renderer |
| `hack/fetch-bundles.py` | Fetches the pinned bundles anonymously from quay.io and verifies digests |
| `hack/extract-operand-manifests.py` | Generates the operand manifests, component CRDs and the union role from the bundles |
| `hack/check-bundle.py` | Checks the generated bundle against the POC contract and `release-set.yaml` |
| `hack/configmap-catalog.py` | Renders the POC ConfigMap-backed CatalogSource from `bundle/` |
| `bundle/` | The generated OLM bundle (one CSV, thirteen CRDs) |
| `test/cluster/` | Live-cluster install verification harness, see its [README](test/cluster/README.md) |
| `AGENTS.md` | Instructions for coding agents working in this repository |

## Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Go | go1.27.1 | `go.mod` declares `go 1.24.0` (scaffold default) |
| operator-sdk | v1.42.3 | kubebuilder `go.kubebuilder.io/v4` layout |
| controller-gen | v0.18.0 | Downloaded into `bin/` by the Makefile |
| envtest | Kubernetes 1.33.0 | Downloaded into `bin/k8s/` by `make test` |
| Python | 3, with PyYAML from `hack/requirements.txt` in `.venv` | Bundle fetch, extraction, checks, catalog, parity |
| podman | 5.7.0 | Installed but not used; the operator image is built on the cluster |

## Generated operand manifests

`make operand-manifests` writes 90 manifests to `internal/operands/manifests/`
(plus `provenance.json`), the twelve component CRDs to `config/crd/bases/`, and the
union role to `config/rbac/operand_union_role.yaml`:

| Component | Manifests | Of which ClusterRoles / ClusterRoleBindings |
| --- | --- | --- |
| NHC | 12 | 3 / 2 |
| SNR | 15 | 4 / 2 |
| SBR | 24 | 15 / 3 |
| FAR | 15 | 4 / 2 |
| MDR | 12 | 4 / 2 |
| NMO | 12 | 3 / 2 |
| **Total** | **90** | |

Each component's set includes the `<serviceaccount>-all-namespaces` ClusterRole and
ClusterRoleBinding that copy the CSV's namespaced `permissions` cluster-wide and
append get/list/watch on `namespaces`, as OLM does for an all-namespaces install
(design brief D7). Never hand-edit these files;
regenerate them.

## Build and test

```sh
python3 -m venv .venv
.venv/bin/pip install -r hack/requirements.txt

make bundles                  # fetch the pinned bundles into .cache/bundles and verify digests
make operand-manifests-check  # committed manifests, CRDs and union role match the bundles
make generate manifests       # controller-gen: deepcopy, CRD and RBAC
make test                     # Go unit and envtest suites
make test-offline             # Python tests and bash syntax check of test/cluster (no cluster)
```

`make operand-manifests` regenerates the operand manifests after a deliberate
release-set change. `make bundle` and `make bundle-check` generate and check the
bundle; `make catalog-configmap` renders the POC catalog (next section).

## Operator image and POC catalog

**Registry choice:** the OpenShift internal image registry of the disposable test
cluster (plan Task 8, option B). No external registry credentials are needed. The
image is built on the cluster with an OpenShift binary Docker build in its own
namespace `wao-poc-build`, not in the install namespace, because preflight
(WAO-INST-00) requires `openshift-workload-availability` to be absent and OLM
creates it later. The bundle references the image **by digest**.

The build uploads a clean `git archive` of `HEAD`, never the working directory, so
git-ignored files such as kubeconfigs are never sent to the cluster.

```sh
KC=/path/to/disposable-cluster.kubeconfig   # always passed explicitly
SRC=$(mktemp -d) && git archive HEAD | tar -x -C "$SRC"

oc create namespace wao-poc-build --kubeconfig "$KC"
oc new-build --binary --name wao -n wao-poc-build --strategy docker --kubeconfig "$KC"
# Let pods in the install namespace pull from the build namespace (works before it exists).
oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:openshift-workload-availability -n wao-poc-build --kubeconfig "$KC"
oc start-build wao -n wao-poc-build --from-dir="$SRC" --follow --kubeconfig "$KC"

DIGEST=$(oc get istag wao:latest -n wao-poc-build --kubeconfig "$KC" -o jsonpath='{.image.metadata.name}')
IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@$DIGEST

make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check
make catalog-configmap DEFAULT_CHANNEL=alpha   # writes dist/wao-poc-catalog.yaml (git-ignored)
```

The committed bundle currently references
`image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@sha256:6077f4265aaf49de3e445e07bd7ee1750171951cdc2d7de4a11f7d8f63328671`
(linux/amd64). A different cluster needs its own build and a regenerated bundle.

`dist/wao-poc-catalog.yaml` holds a ConfigMap with the CSV and thirteen CRDs and a
`sourceType: internal` CatalogSource named `wao-poc-catalog` in
`openshift-marketplace` (design brief D6). It is for the POC install case only. The
upgrade case needs an FBC catalog image (`make catalog-build catalog-push`).

## Install

On a disposable cluster with no medik8s operators or CRDs installed:

1. `oc apply -f dist/wao-poc-catalog.yaml` and wait for the CatalogSource to be `READY`.
2. Create the namespace `openshift-workload-availability` with the annotation
   `openshift.io/node-selector: ""`, an OperatorGroup with an empty spec (all
   namespaces), and a Subscription to package `workload-availability-operator`,
   channel `alpha`, source `wao-poc-catalog` in `openshift-marketplace`.
3. Approve the InstallPlan. The CSV `workload-availability-operator.v0.1.0`
   reaches `Succeeded` and owns all thirteen CRDs.
4. WAO creates the config `cluster` with every component `Disabled` (D4). Enable a
   component with, for example:

   ```sh
   oc patch workloadavailabilityconfig cluster --type merge \
     -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"}}}}'
   ```

`test/cluster/02-install-wao.sh` performs steps 2 and 3. The harness in
[test/cluster/](test/cluster/README.md) runs the whole install case (plan section 4).
It writes raw output only to the git-ignored `evidence/`.

## What Enabled and Disabled mean

**Enabled** renders the component's operand objects from the pinned bundle and
applies them with server-side apply: manager Deployment, Services, ServiceAccounts,
roles and bindings, ConfigMaps and webhook configurations. The phase becomes
`Available` once the managers are ready and, for NHC, SNR, FAR and NMO, the
service-ca CA bundles are injected into the webhooks (D1).

**Disabled** (the default for every component) means WAO has not created, or has
removed, the operand objects it renders. Specifically:

- Installing WAO creates no remediation policy, remediation request, native config,
  node agent, operand Deployment or webhook configuration. The CRDs are installed
  regardless, because the CSV owns them (D8).
- Disabling removes the component's webhook configurations along with the manager
  (D2). A `Fail` webhook without a backend would block even deleting the
  component's objects, and WAO never switches a webhook to `Ignore`. While a
  component is disabled its objects are not validated.
- Disable is **manager-level** (D5). It does **not** stop what the component created
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
3. Delete the Subscription and the CSV in `openshift-workload-availability`. OLM
   removes WAO's Deployment; CRDs remain, as with any OLM uninstall.
4. If desired, remove what remains: delete the SNR config
   `self-node-remediation-config` (its agent DaemonSet is garbage-collected), the
   SNR template and Secret `self-node-remediation-certificates`, the thirteen CRDs
   (this deletes every custom resource of those kinds), the NHC aggregation
   ClusterRole and binding, the ConsolePlugin, the `medik8s-leases` namespace, the
   CatalogSource and its ConfigMap, the namespace and the `wao-poc-build` namespace.

`test/cluster/18-uninstall.sh` performs this cleanup.

## Security notes

- WAO's operand ClusterRole (`config/rbac/operand_union_role.yaml`) is the union of
  every rule of every Role and ClusterRole it renders, plus RBAC `bind` and the
  rules it needs itself (D7). Kubernetes RBAC escalation prevention only lets WAO
  create roles whose rules it holds. The union therefore includes:
  - SCC `use` on `privileged`, because the SNR and SBR CSVs grant it for their agents;
  - NMO's `oauth.openshift.io` wildcard;
  - cluster-wide `clusterroles` and `clusterrolebindings` management from NHC and SBR.
- Each component's namespaced CSV `permissions` are also granted cluster-wide
  through `<serviceaccount>-all-namespaces`, with OLM's get/list/watch rule on
  `namespaces` appended, exactly as OLM does for the all-namespaces install mode
  these CSVs support. For FAR this means its manager can read Secrets (fence
  credentials) in every namespace, which upstream FAR requires.
- Enabling SNR starts privileged node agents on every eligible node (D3).
- No API field can override a component image; the pinned digests are reported in
  the config status (`releaseSet`).

## Known upstream issues

WAO copies each component's Deployment and RBAC faithfully, by design, so upstream
defects carry over unchanged.

- **MDR v0.7.0 memory limit.** The upstream CSV limits the MDR manager to 30Mi of
  memory. The `/manager` binary is 53 MB, and its page-cache pages count against
  that limit. When the binary is not already cached on the node, the container
  thrashes re-reading it and never reaches `main()`: no log output, the health
  port never opens, and the liveness probe kills it every 60 s (exit 2, not
  OOMKilled). This made WAO-INST-09 (and WAO-INST-12 as a knock-on) fail in 2 of
  4 live runs. The same bundle installed standalone by OLM, without WAO, fails
  the same way: 6 of 6 cold-cache starts failed and 9 warm starts were Ready in
  about 13 s. With only the limit raised, 40Mi started but still thrashed and 64Mi
  started cleanly. The OLM-deployed and WAO-rendered MDR Deployments match in
  everything that matters, and MDR caches nothing in its own namespace. The fix
  is upstream: raise the limit to 64Mi or more.

## Deviations from the plan

Bugs in the plan found and fixed during implementation:

1. Operand extraction keeps optional webhook fields, such as NMO's
   `timeoutSeconds`, instead of dropping them.
2. The union role covers every rule of every Role and ClusterRole WAO creates, not
   only the CSV permissions, to avoid RBAC escalation errors. D7 is reworded.
3. Namespaced CSV permissions are also rendered cluster-wide, as OLM does for
   `AllNamespaces`. This fixed FAR's Secret access and webhook timeout.
4. The image is built in `wao-poc-build`, not in the install namespace, because
   preflight requires that namespace to be absent.
5. Harness scripts are numbered by case ID (`NN` = `WAO-INST-NN`), and their checks
   are stricter: an API error fails a check instead of counting as "absent".
6. FAR v0.8.0 rejects a template without parameters, so the dry-run template
   carries one `nodeparameters` entry (field names are lower case).
7. The CSV `relatedImages` lists the seven component images but not the WAO image
   itself; operator-sdk builds the list only from `RELATED_IMAGE_*` environment
   variables.
8. A WAO bug found by the live tests: when OLM copies a CSV's namespaced
   `permissions` into a cluster-wide ClusterRole for an all-namespaces install, it
   also appends get/list/watch on `namespaces`. WAO's copy lacked that rule, so the
   NMO manager could not list or watch namespaces, its cache for the `medik8s-leases`
   Namespace never synced, and it exited about every 2.5 minutes, which failed
   WAO-INST-12. A standalone OLM install of the same NMO v0.21.0 bundle had the extra
   rule and ran without restarts, confirming the cause. WAO now reproduces the rule
   in every `<serviceaccount>-all-namespaces` ClusterRole, and WAO-INST-10 checks it.

## License

Apache License 2.0; see [LICENSE](LICENSE).
