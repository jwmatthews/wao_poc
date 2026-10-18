# wao_poc — Workload Availability Operator proof of concept

This repository is a **proof of concept** for consolidating the
[medik8s](https://github.com/medik8s) node remediation operators behind a single
operator, the Workload Availability Operator (WAO). It exists to test an approach.
It is not a supported product, not a migration tool and not the final design.

The POC installs all six upstream components as managed operands:

| Component | What it does |
| --- | --- |
| [Node Health Check (NHC)](https://github.com/medik8s/node-healthcheck-operator) | Watches node health and creates remediation requests from templates |
| [Self Node Remediation (SNR)](https://github.com/medik8s/self-node-remediation) | Remediates unhealthy nodes with per-node agents that reboot themselves |
| [Storage Based Remediation (SBR)](https://github.com/medik8s/storage-based-remediation) | Remediates nodes through shared-storage messaging and per-node agents |
| [Fence Agents Remediation (FAR)](https://github.com/medik8s/fence-agents-remediation) | Remediates nodes by running fence agents against their management interfaces |
| [Machine Deletion Remediation (MDR)](https://github.com/medik8s/machine-deletion-remediation) | Remediates nodes by deleting their Machine so the Machine API replaces it |
| [Node Maintenance (NMO)](https://github.com/medik8s/node-maintenance-operator) | Cordons and drains a node on explicit request |

The selected component versions, operand image digests and embedded commits are in
[release-set.yaml](release-set.yaml). A snapshot may include development bundles;
the CSV version alone does not establish a published release. Floating tags such
as `latest` are resolved only when refreshing that file. WAO deploys the recorded
digests, including those passed to operands for their agents.

## The idea in one paragraph

Today each component is a separate OLM package with its own CSV, its own API
ownership and its own upgrade lifecycle. WAO replaces that with **one OLM package
that owns all the component APIs** plus a cluster-scoped `WorkloadAvailabilityConfig`
named `cluster`. A lifecycle controller installs each component's unchanged
controller-manager as a separate operand when an administrator enables it. Every
component starts **Disabled**. See [docs/archive/bootstrap/design-brief.md](docs/archive/bootstrap/design-brief.md).

## Status

The live install results below describe earlier release sets. The current image
snapshot has been checked locally and has not been tested on a live cluster.

| Step | State |
| --- | --- |
| Design brief | Written |
| Implementation plan for the install case | Written: [docs/archive/bootstrap/implementation-plan.md](docs/archive/bootstrap/implementation-plan.md) |
| Implementation | Done: Tasks 1–10 (operator, operand manifests, bundle, image, docs); the OADP-style rework (Tasks 1–13) is on branch `explore_how_oadp_updates_third_party_bundles`, cluster verification pending |
| Live install verification | Run on a disposable OpenShift 4.22 cluster (3 nodes, `HighlyAvailable`): four full runs of 19 cases. Runs found two WAO RBAC bugs, both fixed (see [Deviations from the plan](#deviations-from-the-plan), items 3 and 8). The final run passed 17 of 19: WAO-INST-09 and WAO-INST-12 failed only because the upstream MDR manager could not start under its 30Mi memory limit, which reproduces without WAO (see [Known upstream issues](#known-upstream-issues)). Every other case passed. A fifth run on 2026-10-05 against a fresh OpenShift 5.0.0-rc.5 cluster (3 nodes, `HighlyAvailable`, classic OLM) through the since-removed `test/cluster/full-run.sh` harness passed all 19 cases, including MDR, which started with a warm page cache that time. Raw results are not committed |
| Upgrade scenarios | Future plan |

## Layout

| Path | Contents |
| --- | --- |
| [docs/archive/bootstrap/](docs/archive/bootstrap/README.md) | Historical design brief, operand research and implementation plan used to bootstrap the project |
| `release-set.yaml` | The pinned upstream release tags, commits and image digests the POC installs |
| `api/v1alpha1/` | The `WorkloadAvailabilityConfig` API |
| `internal/controller/` | The lifecycle controller and the default-config bootstrap |
| `internal/operands/` | The embedded runtime manifests and the renderer |
| `config/operands/<k>/` | Per operand: `vendored/` (copy of the operand's `config/` tree), `VENDORED.yaml` (source and commit), `rbac/` and `runtime/` kustomize overlays |
| `hack/update-release-set.sh`, `hack/image-commit.sh` | Resolve tags, image digests and the commit embedded in each published image into `release-set.yaml` |
| `hack/update-operand-manifests.sh`, `hack/verify-operand-manifests.sh` | Copy the upstream trees at the recorded commits; offline CI verification |
| `hack/cluster-build.sh`, `hack/cluster-install.sh`, `hack/cluster-uninstall.sh` | On-cluster build and OLM install for a disposable cluster |
| `bundle/` | The generated OLM bundle (one CSV, thirteen CRDs, twenty-one standalone ClusterRoles, and the SBR agent's ServiceAccount and ClusterRoleBinding) |
| `config/catalog/`, `catalog/` | Committed CatalogSource and Subscription templates; the rendered file-based catalog |
| `AGENTS.md` | Instructions for coding agents working in this repository |

## Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Go | go1.27.1 | `go.mod` declares `go 1.24.0` (scaffold default) |
| operator-sdk | v1.42.3 | kubebuilder `go.kubebuilder.io/v4` layout |
| controller-gen | v0.18.0 | Downloaded into `bin/` by the Makefile |
| envtest | Kubernetes 1.33.0 | Downloaded into `bin/k8s/` by `make test` |
| kustomize, yq, opm | Pinned in the Makefile | Downloaded into `bin/` on demand; render manifests and the catalog |
| jq | On PATH | Generate Go image bindings from `release-set.yaml` |
| podman | 5.7.0 | Installed but not used; the operator image is built on the cluster |

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

## Build and test

Run from the repository root (the `cd` command works from any directory inside the checkout):

```sh
cd "$(git rev-parse --show-toplevel)"
make verify-operand-manifests # offline: copies, pins, ServiceAccount coverage and bundle shape agree
make generate manifests       # controller-gen: deepcopy, CRD and RBAC
make test                     # Go unit and envtest suites
make test-offline             # verify-operand-manifests plus the operand pipeline regression tests (no cluster)
GOTOOLCHAIN=go1.24.13 make lint # match the Go 1.24 toolchain used by CI's pinned linter
```

GitHub Actions runs the Go suites, lint, `make verify-operand-manifests` and the offline tests.
Install the required tools and populate the Go module cache with `go mod download` first
(or use an existing `vendor/` directory). The operand regression tests disable module and
toolchain downloads; with those prerequisites available, offline checks need no network or
cluster. CI prepares the module cache before running them.

Operand manifests are copied from each operand checkout, following OADP's non-admin-controller
pattern. `make update-release-set` records the latest release tag, image digests and the git
commit embedded in each published image into `release-set.yaml`; `make update-operand-manifests`
copies `config/` from a checkout at that commit into `config/operands/<k>/vendored/` (checkouts
live in `.cache/operands`, or set `NHC_PATH` and friends), renders the runtime manifests the Go
renderer embeds, generates Go image bindings, and syncs `RELATED_IMAGE_*`.
Use `make bump-operands` for the complete sequence: resolve published images, copy
configuration, generate manifests and bindings, then verify consistency. `OPERAND_TAG` defaults
to `latest`, the post-submit main build; pass `OPERAND_TAG=release` for each component's latest
GitHub release, `OPERAND_TAG=pinned` to keep the current tags, or override one component with
`NHC_TAG=...`. Operand releases can lag files the `config/operands` wrappers rely on.
The steps run sequentially, including with parallel Make, and finish with component and renderer
Go tests. Review the diff before committing;
CI runs `make verify-operand-manifests`, which is offline. Operand RBAC ships in the WAO
CSV via `--extra-service-accounts` and OLM creates it at install; WAO creates no RBAC itself.
`release-set.yaml` records per operand `repo`, `tag`, `commit` and
`images.<ENV>.{tagged,pinned}`.

## Build, catalog and install on a disposable cluster

The operator, bundle and a file-based catalog (FBC) image are built on the cluster with binary
Docker builds in namespace `wao-poc-build`. The operator image comes from a clean `git archive
HEAD`; the bundle and catalog are generated from the working tree, so `hack/cluster-build.sh`
refuses a dirty tree unless `ALLOW_DIRTY=1` is set. The bundle references the operator image by
digest and the catalog references the bundle by digest. No external registry is needed. The
kubeconfig is always passed explicitly. The build rewrites `bundle/` and
`config/manager/kustomization.yaml`; `make bundle-reset` restores the committed bundle.

```sh
KC=/path/to/disposable-cluster.kubeconfig
hack/cluster-build.sh "$KC"      # builds three images, writes dist/catalogsource.yaml
hack/cluster-install.sh "$KC"    # CatalogSource, namespace, OperatorGroup, Subscription; waits for the CSV
hack/cluster-uninstall.sh "$KC"  # removes them; CRDs stay
```

`config/catalog/` holds the committed CatalogSource (`sourceType: grpc`) and Subscription
templates. `make catalog-fbc BUNDLE_IMG=<ref>` renders `./bundle` into `catalog/` with `opm` and
`make catalog-build` builds the image locally when a container tool is available. The shared
`make dev-olm-deploy` from medik8s/tools (`TOOLS_DIR=<path to medik8s/tools>`) installs the bundle
with `operator-sdk run bundle` and needs no catalog image.

## What Enabled and Disabled mean

**Enabled** applies the component's operand objects with server-side apply: the
manager Deployment, Services, ConfigMaps and webhook configurations, rendered from the
vendored `config/default` copy (the `objects.yaml` embedded in the binary) with the pinned
image digests substituted. The operand ServiceAccounts, Roles and bindings are not part of
this: OLM creates them from the WAO CSV at install, and they exist whether or not the
component is Enabled. The phase becomes
`Available` once the managers are ready and, for NHC, SNR, FAR and NMO, the
service-ca CA bundles are injected into the webhooks (D1).

**Disabled** (the default for every component) means WAO has not created, or has
removed, the operand objects it renders (not the OLM-owned RBAC). Specifically:

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
4. Operand RBAC is owned by OLM and is removed with the CSV. What can remain after
   uninstall is: the thirteen CRDs (OLM does not delete them; deleting them removes every
   custom resource of those kinds), agent DaemonSets owned by component configs such as
   the SNR config `self-node-remediation-config`, the service-ca Secrets
   `<prefix>-webhook-server-cert`, and objects the upstream managers created (NHC's
   aggregation ClusterRole, the ConsolePlugin, the `medik8s-leases` namespace). If desired,
   also delete the CatalogSource, the namespace and the `wao-poc-build` namespace.

`hack/cluster-uninstall.sh` is the scripted path: it performs steps 2 and 3 and removes the
CatalogSource; the CRDs stay.

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
9. 2026-10: the Python pipeline, the union role and the ConfigMap catalog were replaced by the
   OADP-style approach (GitHub #12 to #16): operand `config/` trees are copied from upstream
   checkouts at the commit embedded in the published image, operand RBAC ships in the WAO CSV and
   OLM creates it, and the dev catalog is an FBC image. Items 2, 3 and 8 are historical; OLM now
   does the cluster-wide promotion of CSV `permissions` for the `AllNamespaces` OperatorGroup.
   Trade-off accepted: operand ServiceAccounts and roles exist from install onward, even while
   every component is Disabled.

## License

Apache License 2.0; see [LICENSE](LICENSE).
