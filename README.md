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
| Implementation | Not started |
| Upgrade scenarios | Future plan |

## Layout

| Path | Contents |
| --- | --- |
| `docs/design-brief.md` | Approach, decisions and non-goals |
| `docs/operands.md` | Facts about each upstream operand, derived from its published bundle |
| `docs/implementation-plan.md` | Task-by-task plan with tests, written for a coding agent |
| `release-set.yaml` | The pinned upstream bundle and image digests the POC installs |
| `hack/fetch-bundles.py` | Fetches the pinned bundles anonymously from quay.io and verifies digests |
| `AGENTS.md` | Instructions for coding agents working in this repository |

## Quick start for contributors

```sh
python3 -m venv .venv
.venv/bin/pip install -r hack/requirements.txt
.venv/bin/python hack/fetch-bundles.py --release-set release-set.yaml --out .cache/bundles
```

Then follow [docs/implementation-plan.md](docs/implementation-plan.md) from Task 1.

## License

Apache License 2.0; see [LICENSE](LICENSE).
