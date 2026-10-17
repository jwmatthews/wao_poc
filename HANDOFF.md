# Handoff: adopting OADP's operand manifest approach

Written 2026-10-16 at the end of a design session. Branch
`explore_how_oadp_updates_third_party_bundles`, based on `dd7e250`. Nothing from this session is
committed yet.

## Where things stand

The design is finished and filed as GitHub issues. No implementation has started.

| Issue | Scope | Order |
|---|---|---|
| [#12](https://github.com/jwmatthews/wao_poc/issues/12) | Parent: decisions, assumptions, definition of done | |
| [#13](https://github.com/jwmatthews/wao_poc/issues/13) | Sync tooling: `update-release-set`, `update-operand-manifests`, `verify-operand-manifests` | 1 |
| [#14](https://github.com/jwmatthews/wao_poc/issues/14) | ConfigMap dev catalog replaced by an FBC image via the shared `dev-olm-catalog-*` targets | 2 |
| [#15](https://github.com/jwmatthews/wao_poc/issues/15) | Operand RBAC moves from the controller to the WAO CSV, owned by OLM | 3 |
| [#16](https://github.com/jwmatthews/wao_poc/issues/16) | Remove the Python manifest pipeline | 4 |

#13 through #16 are linked as GitHub sub-issues of #12. #14 must merge before #15, because the
standalone ClusterRoles that #15 adds to the bundle cannot be served by the ConfigMap catalog.

## Files from this session (all uncommitted)

- `docs/operand-manifests-oadp-approach.md`: the analysis. How OADP does it, what we do today, the
  prototype evidence (rule counts, zero name collisions, CRD diffs), gaps, the RBAC union answer,
  the Make-versus-code answer, the proposed layout and Makefile sketch, trade-offs, verification plan.
- `docs/operand-manifests-oadp-approach-issues.md`: the exact text filed as #12 to #16, with a header
  pointing at the live issues. GitHub is the live copy.
- `EXPLORE_HOW_OADP_UPDATES.md`: the original brief that started the work.

Other untracked files in the tree (`OLM_V1_READINESS.md`, `docs/nhc-*.md`, `docs/superpowers/`,
`evidence/`, `run-nhc-e2e.sh`, `run_lint.sh`, `test/rhwa/`) predate this session and are unrelated.

Suggested first commit: the two `docs/operand-manifests-oadp-approach*.md` files. Decide whether
`EXPLORE_HOW_OADP_UPDATES.md` is worth keeping or is superseded by the approach doc.

## Decisions made, with the reason

Each is also recorded in #12. Listed here so nobody re-litigates them by accident.

1. **Kustomize sources only.** Copy `config/crd/bases` and `config/rbac` from a checkout, render
   `config/default` for runtime manifests. The operand's `bundle/` and `make bundle` are never used.
   WAO's CSV replaces theirs. Same as OADP with the non-admin controller.
2. **Unbound ClusterRoles ship as standalone bundle objects.** Twenty of them: six `metrics-reader`,
   four `ext-remediation`, SBR admin/editor/viewer. We neither invent bindings nor drop them.
3. **The git ref comes from the image, not from a tag.** Every medik8s operator embeds
   `version.GitCommit` via ldflags in `hack/build.sh`; `go version -m` on the extracted binary reads
   it. Verified: NHC v0.12.0 image embeds `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`, which is
   `git rev-parse v0.12.0`. OCI `vcs-ref` labels come from the UBI base image and are useless.
4. **"Latest" means the latest GitHub release**, via the `releases/latest` API. Quay has stray tags
   (NHC `v5.8.0`, `v9.9.9-ci`) with no release. `OPERAND_TAG=` and `<COMPONENT>_TAG=` override.
5. **Checkouts in `.cache/operands/<component>`**, git-ignored. `OPERAND_SRC_DIR` or
   `<COMPONENT>_PATH` points at an existing checkout, modelled on OADP's `NON_ADMIN_CONTROLLER_PATH`.
6. **Copied files under `config/operands/<component>/{crd,rbac}/`**, like OADP's
   `config/non-admin-controller_rbac`.
7. **CI never runs the sync.** `make update-operand-manifests` is a developer action followed by a
   commit. CI runs the offline `make verify-operand-manifests` (stamp files, digests,
   `--extra-service-accounts` coverage, no unexpected standalone RBAC, `git diff --exit-code`).
8. **Parent issue plus one sub-issue each**, so the FBC switch and the RBAC move are reviewed apart.

## Assumptions to keep true

- The Go renderer keeps creating Deployment, Service, webhook configurations and ConfigMaps at
  enable time. Only RBAC moves to OLM.
- Operand ServiceAccounts, Roles and bindings exist from install onward, even while every component
  is Disabled. OADP accepts the same for the non-admin controller.
- `AllNamespaces` install mode makes OLM promote CSV `permissions` Roles to ClusterRoles with
  get/list/watch on `namespaces` appended (README deviation 8). More Roles go through that now.
- `--extra-service-accounts` must list all seven operand SAs:
  `node-healthcheck-controller-manager`, `self-node-remediation-controller-manager`,
  `sbr-operator-controller-manager`, `sbr-operator-sbr-agent`,
  `fence-agents-remediation-controller-manager`, `machine-deletion-remediation-controller-manager`,
  `node-maintenance-operator-controller-manager`. Names were read from checkouts that are ahead of
  the pinned tags; confirm against the copied files when #13 lands.

## Facts worth knowing before starting #13

- The prototype that produced the evidence lived in a session scratchpad and is gone. Section 8 of
  the approach doc has the layout and Makefile sketch; section 4 has the numbers to reproduce.
- Kustomize name references break if RBAC is deleted inside the same build. Filter by kind with
  `yq` after the build. Upstream Deployments have no `volumes`, so the webhook cert patch must be a
  strategic merge, not a JSON `add`.
- The metrics Services live in `config/rbac` upstream and get dragged along by the rbac copy. Drop
  them from the rbac wrapper; they stay with the renderer.
- medik8s release workflows are `workflow_dispatch`: check out a ref, push `v$VERSION` images, then
  create the GitHub release with the same tag and attach `bundle.tar.gz`. The optional
  `checkout_ref` input is the one way tag and image can diverge, which is why the embedded commit
  check matters.
- SBR builds operator and agent from one Dockerfile and one commit. Read the commit from both images
  and fail if they differ.

## Facts worth knowing before starting #14

- The local medik8s/tools checkout at `~/git/medik8s/tools` was stale (2026-09-16). `dev-olm-*`
  targets are on origin/main as of 2026-10-15. Run `git pull` there first.
- The wao_poc Makefile resolves `TOOLS_DIR` to `../tools`, which from `~/git/jwmatthews/wao_poc`
  does not exist, so it downloads into `.tools/`. Use `TOOLS_DIR=~/git/medik8s/tools`.
- `make dev-olm-deploy` is unaffected by any of this: `operator-sdk run bundle` renders an FBC on
  the fly and never used the ConfigMap catalog. It runs `operator-sdk bundle validate
  --select-optional suite=operatorframework` on every deploy, which is free validation for #15.
- `DEV_OLM_RELEASED_BUNDLE_REPOSITORY` defaults to a WAO path on registry.redhat.io that does not
  exist. Keep `PREVIOUS_VERSION` empty or override `DEV_OLM_PREVIOUS_BUNDLE_IMAGE`.
- Users of the ConfigMap catalog today: `make catalog-configmap` (`hack/configmap-catalog.py`),
  `dist/wao-poc-catalog.yaml`, README lines 130 to 224, and the live-cluster build step.

## Facts worth knowing before starting #15

- Runtime RBAC code: `internal/operands/render.go` (`namespacedKinds`, `kindOrder`), each
  component's `ManagedKinds` in `internal/components/component.go`, and the listing in
  `internal/controller/workloadavailabilityconfig_controller.go` around line 327.
- WAO grants itself `bind` in `config/rbac/role.yaml` line 93 only to create operand RoleBindings.
  `config/rbac/operand_union_role.yaml` (891 lines) is referenced from
  `config/rbac/kustomization.yaml` line 11 and written by `hack/extract-operand-manifests.py`.
- Design brief D6, D7, D9 and README deviations 2, 3, 8 describe the behaviour being removed.

## Cluster

Any live verification needs a disposable OpenShift cluster confirmed in that session. Last session
had `jmatthews-422-rhwa.kubeconfig` authorized; that authorization does not carry over. The shell
exports a KUBECONFIG for a cluster that is not authorized, so prefix every command with
`KUBECONFIG=<path>` and check cluster identity first. No cluster commands were run this session.

## Suggested next steps

1. Commit the two approach docs on this branch.
2. Start #13. Build `update-operand-manifests` first against the pinned tags and confirm the copied
   files match the numbers in approach doc section 4, then add `update-release-set` and
   `verify-operand-manifests`.
3. Run `make test` and `make test-offline` before each commit, per AGENTS.md.
