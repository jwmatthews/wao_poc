# Handoff: adopting OADP's operand manifest approach

Branch `explore_how_oadp_updates_third_party_bundles`, based on `dd7e250`. Updated 2026-10-17.

## Where things stand

All plan tasks 0 to 13 of `docs/superpowers/plans/2026-10-16-oadp-operand-manifests.md` are
implemented and reviewed on this branch, covering GitHub #12 to #16: sync tooling (#13), FBC dev
catalog (#14), operand RBAC in the WAO CSV (#15) and removal of the Python pipeline (#16). The
final review's fixes (below) are committed too.

The cluster reset (plan Task 14) ran. The cluster verification (plan Task 15) is **BLOCKED**: the
disposable cluster's kubelets have been disconnected from the API server since 2026-10-07, so no
pod can schedule (details in `evidence/2026-10-17-oadp-cluster/RESULTS.md`). Nothing on this
branch has been exercised on a live cluster yet.

Commits since the design docs (`git log --oneline 44f6e47..HEAD`, taken before the commit that
recorded this list):

```
05d7855 docs: final-review minors and HANDOFF refresh
5922a90 hack: cluster-build refuses a dirty tree unless ALLOW_DIRTY=1
1f6a5be operands: opt-in bundle freshness check in verify-operand-manifests
65cd118 rbac: ship the SBR agent's RBAC standalone so its manager can bind it
fad68c1 docs: plan amendments made during execution
b3624fb docs: describe Enabled, Disabled and uninstall under CSV-owned RBAC
af759e2 docs: describe the OADP-style operand flow and FBC install
b0a9aa9 ci: verify operand manifests offline instead of fetching bundles
01db7ef bundle: restore icon and blank createdAt via bundle-reset
5a9fe19 build: remove the Python manifest pipeline and ConfigMap catalog
a006ba1 test: enable and disable every component without RBAC rendering
dbaa6ad operands: fail verification when an operand rbac overlay does not build
6c9018b operands: offline verification of copies, pins, SA coverage and bundle shape
c6153d0 rbac: ship operand RBAC in the WAO CSV and stop creating it at runtime
c8c9198 Makefile: fail operand-manifests on a missing pinned digest or manager env
0c02ff9 operands: render runtime manifests from the kustomize overlays
b7f27a2 operands: rbac and runtime kustomize overlays over the upstream copies
cb95fa8 operands: stage the new upstream copy before removing the old one
799ff77 operands: copy upstream config trees at the recorded commits
f49cde6 operands: distinguish image-commit failures from a missing embedded commit
dbe8394 operands: discover versions, digests and embedded commits for release-set.yaml
71c289e hack: harden cluster scripts: absolute kubeconfig, visible build logs, digest check
6d80e56 hack: disposable-cluster build and install scripts for the FBC catalog
0c7e536 build: anchor the catalog ignore patterns to the repo root
2c90382 build: committed CatalogSource and Subscription for the FBC install
40690b5 build: render the local bundle into a file-based catalog
756f247 docs: record the OADP-style operand manifest design and plan
```

`release-set.yaml` now records `version`, `tag` and `commit` per operand. The pinned versions are
`v5.8.0` labels over `latest` or `v5.8.0` image tags, with the embedded git commits recorded; the
copied trees under `config/operands/<k>/upstream/` come from those commits. The bundle ships
twenty-one standalone ClusterRoles plus the SBR agent's ServiceAccount and ClusterRoleBinding.

`make test` note: `verify-no-changes` fails on pre-existing untracked files, in particular the
untracked `evidence/` tree. Until that is cleaned up, run the tests with the wrapper command:

```
make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes
```

Other untracked files in the tree (`OLM_V1_READINESS.md`, `docs/nhc-*.md`, `docs/superpowers/`,
`evidence/`, `run-nhc-e2e.sh`, `run_lint.sh`, `test/rhwa/`, `EXPLORE_HOW_OADP_UPDATES.md`) predate
this work and are unrelated.

## Decisions made, with the reason

Each is also recorded in #12. Listed here so nobody re-litigates them by accident.

1. **Kustomize sources only.** Copy `config/crd/bases` and `config/rbac` from a checkout, render
   `config/default` for runtime manifests. The operand's `bundle/` and `make bundle` are never used.
   WAO's CSV replaces theirs. Same as OADP with the non-admin controller.
2. **Unbound ClusterRoles ship as standalone bundle objects.** Nineteen of them: six `metrics-reader`,
   four `ext-remediation`, SBR admin/editor/viewer. We neither invent bindings nor drop them. The
   SBR agent's two ClusterRoles (`sbr-operator-sbr-agent-role`, `sbr-operator-sbr-agent-privileged-scc`)
   also ship standalone, for twenty-one in all: the SBR manager binds them by name at runtime.
3. **The git ref comes from the image, not from a tag.** Every medik8s operator embeds
   `version.GitCommit` via ldflags in `hack/build.sh`; `go version -m` on the extracted binary reads
   it. Verified at design time: NHC v0.12.0 image embeds `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`, which is
   `git rev-parse v0.12.0`. OCI `vcs-ref` labels come from the UBI base image and are useless.
4. **"Latest" means the latest GitHub release**, via the `releases/latest` API. Quay has stray tags
   (`v9.9.9-ci`) with no release. `OPERAND_TAG=` and `<COMPONENT>_TAG=` override.
5. **Checkouts in `.cache/operands/<component>`**, git-ignored. `OPERAND_SRC_DIR` or
   `<COMPONENT>_PATH` points at an existing checkout, modelled on OADP's `NON_ADMIN_CONTROLLER_PATH`.
6. **Copied trees under `config/operands/<component>/upstream/`**, like OADP's
   `config/non-admin-controller_rbac`, with `rbac/` and `runtime/` kustomize overlays beside them
   and an `UPSTREAM.yaml` stamp recording source and commit.
7. **CI never runs the sync.** `make update-operand-manifests` is a developer action followed by a
   commit. CI runs the offline `make verify-operand-manifests` (`UPSTREAM.yaml` stamps, digests,
   `--extra-service-accounts` coverage, no unexpected standalone RBAC, `git diff --exit-code`).
8. **Parent issue plus one sub-issue each**, so the FBC switch and the RBAC move are reviewed apart.

## Assumptions to keep true

- The Go renderer keeps creating Deployment, Service, webhook configurations and ConfigMaps at
  enable time. Only RBAC moves to OLM.
- Operand ServiceAccounts, Roles and bindings exist from install onward, even while every component
  is Disabled. OADP accepts the same for the non-admin controller.
- `AllNamespaces` install mode makes OLM promote CSV `permissions` Roles to ClusterRoles with
  get/list/watch on `namespaces` appended (README deviation 8). More Roles go through that now.
- `--extra-service-accounts` (`OPERAND_SERVICE_ACCOUNTS`) lists six folded ServiceAccounts:
  `node-healthcheck-controller-manager`, `self-node-remediation-controller-manager`,
  `sbr-operator-controller-manager`, `fence-agents-remediation-controller-manager`,
  `machine-deletion-remediation-controller-manager`, `node-maintenance-operator-controller-manager`.
  The SBR agent's RBAC (`sbr-operator-sbr-agent`, listed in `OPERAND_STANDALONE_SERVICE_ACCOUNTS`)
  is deliberately not folded: the SBR manager creates ClusterRoleBindings to
  `sbr-operator-sbr-agent-role` and `sbr-operator-sbr-agent-privileged-scc` by name, so those
  ClusterRoles must keep their upstream names. `make verify-operand-manifests` checks both lists.

## Final review findings

- **C1 (Critical), fixed: SBR agent RBAC was lost.** The SBR manager
  (`internal/controller/storagebasedremediationconfig_controller.go` upstream) creates
  ClusterRoleBindings whose `roleRef` names `sbr-operator-sbr-agent-role` and
  `sbr-operator-sbr-agent-privileged-scc` verbatim. Folding `sbr-operator-sbr-agent` into the CSV
  gave the first an OLM-generated name, and the second was rendered nowhere because upstream's
  `config/rbac` kustomization omits its file. Fix: the agent SA moved to
  `OPERAND_STANDALONE_SERVICE_ACCOUNTS`, so its ServiceAccount, ClusterRole and ClusterRoleBinding
  ship as standalone bundle objects as in upstream's bundle; the SBR rbac overlay lists the upstream
  SCC role file (built with `--load-restrictor LoadRestrictionsNone`); `verify-operand-manifests`
  checks both SA lists and asserts both ClusterRoles are in the bundle.
- **I1, fixed:** `verify-operand-manifests` checks bundle shape, not freshness. `VERIFY_BUNDLE=1`
  now regenerates it with `make bundle-reset` and reports drift; `make test` already covers it.
- **I2, fixed:** `hack/cluster-build.sh` builds the operator image from `git archive HEAD` but the
  bundle from the working tree. It now refuses a dirty tree unless `ALLOW_DIRTY=1` and reminds the
  developer that `make bundle-reset` restores the committed bundle.
- The deferred-minor list and the controller's rulings are in
  `.superpowers/sdd/2026-10-16-oadp-operand-manifests/progress.md`.

## Cluster

Any live verification needs a disposable OpenShift cluster confirmed in that session. Earlier
authorizations do not carry over. The shell exports a KUBECONFIG for a cluster that is not
authorized, so prefix every command with `KUBECONFIG=<path>` and check cluster identity first.

## Suggested next steps

1. Recover or replace the disposable cluster, then run `hack/cluster-build.sh`,
   `hack/cluster-install.sh` and the enable/disable checks in plan Task 15. Pay special attention
   to SBR: enable it, create nothing, and read the SBR manager log for "cluster role binding"
   errors. Record the results here.
2. Split the branch into PRs in merge order (#13, #14, #15, #16) if desired. #14 must merge before
   #15, because the standalone ClusterRoles that #15 adds cannot be served by a ConfigMap catalog.
3. Triage the deferred-minor list in
   `.superpowers/sdd/2026-10-16-oadp-operand-manifests/progress.md`.
