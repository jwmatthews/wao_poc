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
| Implementation | In progress: Tasks 1–8 done (operator, bundle, image, POC catalog) |
| Upgrade scenarios | Future plan |

## Layout

| Path | Contents |
| --- | --- |
| `docs/design-brief.md` | Approach, decisions and non-goals |
| `docs/operands.md` | Facts about each upstream operand, derived from its published bundle |
| `docs/implementation-plan.md` | Task-by-task plan with tests, written for a coding agent |
| `release-set.yaml` | The pinned upstream bundle and image digests the POC installs |
| `hack/fetch-bundles.py` | Fetches the pinned bundles anonymously from quay.io and verifies digests |
| `hack/configmap-catalog.py` | Renders the POC ConfigMap-backed CatalogSource from `bundle/` |
| `AGENTS.md` | Instructions for coding agents working in this repository |

## Quick start for contributors

```sh
python3 -m venv .venv
.venv/bin/pip install -r hack/requirements.txt
.venv/bin/python hack/fetch-bundles.py --release-set release-set.yaml --out .cache/bundles
```

Then follow [docs/implementation-plan.md](docs/implementation-plan.md) from Task 1.

## Operator image and POC catalog

**Registry choice:** the OpenShift internal image registry of the disposable test
cluster (plan Task 8, option B). No external registry credentials are needed. The
image is built on the cluster in its own namespace `wao-poc-build`, not in the
install namespace, because preflight (WAO-INST-00) requires
`openshift-workload-availability` to be absent and OLM creates it later. The bundle
references the image **by digest**.

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
`image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@sha256:784641dbcbd891a0bbd38bca35591f1b46dd9787d586bb1b40d65f8b821c7972`
(linux/amd64). A different cluster needs its own build and a regenerated bundle.

`dist/wao-poc-catalog.yaml` holds a ConfigMap with the CSV and thirteen CRDs and a
`sourceType: internal` CatalogSource named `wao-poc-catalog` in
`openshift-marketplace`. It is for the POC install case only. The upgrade case needs
an FBC catalog image (`make catalog-build catalog-push`).

## Toolchain

Versions used to build this POC (recorded in Task 1):

| Tool | Version | Notes |
| --- | --- | --- |
| Go | go1.27.1 darwin/arm64 | `go.mod` declares `go 1.24.0` (scaffold default) |
| operator-sdk | v1.42.3 (kubernetes v1.33.1, built with go1.26.4) | kubebuilder `go.kubebuilder.io/v4` layout |
| controller-gen | v0.18.0 | Downloaded into `bin/` by the Makefile |
| envtest | Kubernetes 1.33.0 | Downloaded into `bin/k8s/` by `make test` |
| podman | 5.7.0 | The local podman VM is not used; the operator image is built on the cluster |

## License

Apache License 2.0; see [LICENSE](LICENSE).
