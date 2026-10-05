# Agent instructions

This repository is a proof of concept for a single Workload Availability Operator
(WAO) that installs the six upstream medik8s operators (NHC, SNR, SBR, FAR, MDR and NMO)
as operands in one namespace.

## Read first

1. [docs/design-brief.md](docs/design-brief.md): what we are proving and the decisions D1–D10.
2. [docs/operands.md](docs/operands.md): the facts each task relies on.
3. [docs/implementation-plan.md](docs/implementation-plan.md): execute it task by task.
   Each task is test-first and ends with a commit. Do not skip the failing-test step.

## Hard constraints

- Do not modify, fork or rebuild the component operators. Consume the upstream
  images exactly as pinned in `release-set.yaml`, by digest.
- Every component defaults to `Disabled`. Installing WAO must not create a
  remediation policy, remediation request, native config or node agent.
- Never change a component webhook `failurePolicy`, in particular never `Fail` to `Ignore`.
- WAO never adopts an existing object it did not create. It reports the conflict instead.
- No public API field may override a component image.
- Keep `.cache/`, `evidence/`, `.venv/` and any kubeconfig out of Git.

## Cluster work

Live-cluster tests (plan section 4) need a **disposable** OpenShift cluster with
classic OLM that you are authorized to modify, selected through the `KUBECONFIG`
environment variable. The repository never contains cluster credentials or
cluster-identifying details. Do not run cluster tests unless the person you are
working for has confirmed which cluster to use in the current session.

Disposable OpenShift clusters you may use for testing are described in the local
file `DISPOSABLE_OPENSHIFT_CLUSTERS.md`, which points to their kubeconfig files.
Still confirm which one to use before running cluster tests.

- Always pass the kubeconfig explicitly; never rely on the current context.
- Write raw cluster output only to `evidence/<UTC-date>-<run>/`, which is git-ignored.
  Raw output contains API URLs, node names and addresses.
- Commit only sanitized summaries (`results.json`, `REPORT.md`) and only after review.
- Never capture Secret values.
- Use server-side dry-run for admission checks. Never create a real
  `NodeHealthCheck` policy, `StorageBasedRemediationConfig`, `NodeMaintenance` or
  remediation request (SNR, SBR, FAR, MDR) as part of the install tests. These
  objects reboot, fence, delete or drain real nodes.

## Commits

Small commits per task with a `wao:` prefix. Run `make test` and `make test-offline`
before each commit.
