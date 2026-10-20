# Agent instructions

This repository is a proof of concept for a single Workload Availability Operator
(WAO) that installs the six medik8s operators (NHC, SNR, SBR, FAR, MDR and NMO)
as operands in one namespace.

## Hard constraints

- Do not modify, fork or rebuild the component operators. Consume the operand
  images exactly as pinned in `release-set.yaml`, by digest.
- Every component defaults to `Disabled`. Installing WAO must not create a
  remediation policy, remediation request, native config or node agent.
- Never change a component webhook `failurePolicy`, in particular never `Fail` to `Ignore`.
- WAO never adopts an existing object it did not create. It reports the conflict instead.
- No public API field may override a component image.

## Cluster work

Live-cluster tests need a **disposable** OpenShift cluster with
classic OLM that you are authorized to modify.
 
The repository never contains cluster credentials or
cluster-identifying details. Do not run cluster tests unless the person you are
working for has confirmed which cluster to use in the current session.

- Always pass the kubeconfig explicitly; never rely on the current context.
- Commit only sanitized summaries (`results.json`, `REPORT.md`) and only after review.
- Never capture Secret values.
- Use server-side dry-run for admission checks. Never create a real
  `NodeHealthCheck` policy, `StorageBasedRemediationConfig`, `NodeMaintenance` or
  remediation request (SNR, SBR, FAR, MDR) as part of the install tests. These
  objects reboot, fence, delete or drain real nodes.

## Commits

Small commits per task.
Run `make check` before each commit (lint, import order, operand manifest
consistency; read-only, seconds). Run `make test-offline` and `make test` on a
clean tree before pushing. Together they match what CI runs.
