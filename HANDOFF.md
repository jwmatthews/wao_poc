# Handoff: adopting OADP's operand manifest approach

Branch `explore_how_oadp_updates_third_party_bundles`, based on `dd7e250`. Updated 2026-10-16.

## Where things stand

Tasks 1 to 13 of `docs/superpowers/plans/2026-10-16-oadp-operand-manifests.md` are implemented on
this branch, covering GitHub #12 to #16: sync tooling (#13), FBC dev catalog (#14), operand RBAC in
the WAO CSV (#15) and removal of the Python pipeline (#16). Commits since the design docs (`git log
--oneline 44f6e47..HEAD`):

```
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

Cluster verification (plan Tasks 14 and 15) is next and will be run by the controller on a
disposable cluster confirmed in that session. Nothing has been run against a cluster for this work.

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

## Cluster

Any live verification needs a disposable OpenShift cluster confirmed in that session. Earlier
authorizations do not carry over. The shell exports a KUBECONFIG for a cluster that is not
authorized, so prefix every command with `KUBECONFIG=<path>` and check cluster identity first.

## Suggested next steps

1. Cluster verification results (plan Tasks 14 and 15) are pending; record them here when done.
2. Split the branch into PRs in merge order (#13, #14, #15, #16) if desired. #14 must merge before
   #15, because the standalone ClusterRoles that #15 adds cannot be served by a ConfigMap catalog.
3. The deferred-minor list lives in
   `.superpowers/sdd/2026-10-16-oadp-operand-manifests/progress.md` until the final review
   triages it.
