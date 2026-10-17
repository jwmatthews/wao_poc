# GitHub issue drafts: adopt OADP's operand manifest approach

Draft text for one parent issue and four sub-issues. Filed on 2026-10-16 as
[#12](https://github.com/jwmatthews/wao_poc/issues/12) (parent), [#13](https://github.com/jwmatthews/wao_poc/issues/13),
[#14](https://github.com/jwmatthews/wao_poc/issues/14), [#15](https://github.com/jwmatthews/wao_poc/issues/15) and
[#16](https://github.com/jwmatthews/wao_poc/issues/16). GitHub is the live copy; this file is the record.
Background and prototype evidence: [operand-manifests-oadp-approach.md](operand-manifests-oadp-approach.md).

---

## Parent issue

**Title:** Adopt OADP's approach for operand manifests: copy from source checkouts, OLM-owned RBAC, FBC dev catalog, no Python

### Why

Today WAO fetches six published operand bundle images, unpacks them with 869 lines of Python,
rewrites every manifest, computes an 891-line union ClusterRole so the controller may create
operand RBAC at runtime, and installs through a ConfigMap-backed CatalogSource that cannot carry
standalone bundle objects. The pipeline is hard to follow, hard to debug, and the RBAC union
exists only because WAO, not OLM, creates the operand Roles.

OADP ships the non-admin controller (NAC) as an operand with a far simpler pattern:
`make update-non-admin-manifests` copies `config/crd/bases` and `config/rbac` from a local
checkout of the operand into OADP's `config/` tree, OADP's own `make bundle` folds the Roles into
the OADP CSV through `--extra-service-accounts`, and OLM creates the ServiceAccounts, Roles and
bindings at install. OADP never creates RBAC at runtime and needs no union role.

This issue tracks moving WAO to that pattern. The analysis and prototype behind it are in
`docs/operand-manifests-oadp-approach.md`. The prototype showed the folded CSV reproduces the
exact rule set for every operand ServiceAccount and that no name collisions occur across the six
operands once each keeps its upstream `namePrefix`.

### Target state

1. `make update-release-set` discovers the latest release of each operand, resolves the image
   digest, reads the git commit embedded in the image's Go binary, and writes version, digest and
   commit into `release-set.yaml`. A tag override selects any other published image.
2. `make update-operand-manifests` clones or reuses a checkout of each operand under
   `.cache/operands/<component>`, checks out the recorded commit, copies `config/crd/bases` and
   `config/rbac` into `config/operands/<component>/{crd,rbac}/`, renders `config/default` into the
   runtime manifests the Go renderer embeds, syncs `RELATED_IMAGE_*` digests into the manager
   Deployment, and runs `make bundle`. The developer reviews and commits the result.
3. `make bundle` folds every operand Role and ClusterRole bound to an operand ServiceAccount into
   the WAO CSV via `--extra-service-accounts`. Unbound ClusterRoles ship as standalone bundle
   objects. OLM creates all of it at install.
4. The controller no longer creates ServiceAccounts, Roles, ClusterRoles or bindings when a
   component is enabled. `config/rbac/operand_union_role.yaml` and the `bind` grant are deleted.
5. The dev catalog is a file-based catalog (FBC) image built by the shared `dev-olm-catalog-*`
   targets from medik8s/tools, installed through a committed `grpc` CatalogSource.
6. No Python remains in the manifest pipeline.

### Decisions already made

- **Kustomize sources only, no operand bundle build.** We copy `config/` from the checkout like
  OADP does. The operand's own `bundle/` directory, CSV and `make bundle` target are never used.
  WAO's CSV replaces theirs.
- **Unbound ClusterRoles ship as standalone bundle objects.** Six `metrics-reader`, four
  `ext-remediation` and SBR's admin, editor and viewer roles have no binding upstream. We do not
  invent bindings and we do not drop them. This is what forces the dev catalog to FBC.
- **The git ref is derived from the image, not guessed from a tag.** Every medik8s operator is
  built through `hack/build.sh`, which embeds `version.GitCommit=$(git rev-parse HEAD)` via
  ldflags. `go version -m` on the binary extracted from the pinned image returns that commit.
  Verified on `quay.io/medik8s/node-healthcheck-operator:v0.12.0`: embedded commit
  `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f` equals `git rev-parse v0.12.0`. The OCI
  `vcs-ref` and `org.opencontainers.image.revision` labels are inherited from the UBI base image
  and must not be used.
- **"Latest" means the latest GitHub release of each repo** (`releases/latest` API, no auth).
  Quay carries stray tags such as NHC `v5.8.0` and `v9.9.9-ci` with no matching release, so the
  highest image tag is not a safe default. `OPERAND_TAG=v5.8.0` or `OPERAND_TAG=latest` overrides
  it for all components, `<COMPONENT>_TAG` for one.
- **Checkouts live in `.cache/operands/<component>`, git-ignored.** `OPERAND_SRC_DIR` or a
  per-component `<COMPONENT>_PATH` points at an existing checkout instead, modelled on OADP's
  `NON_ADMIN_CONTROLLER_PATH`.
- **Copied files live under `config/operands/<component>/{crd,rbac}/`**, inside the kustomize
  tree operator-sdk already builds from, like OADP's `config/non-admin-controller_rbac`.
- **CI never runs the sync.** `make update-operand-manifests` is a developer action followed by a
  commit. CI runs an offline `make verify-operand-manifests` over committed files.
- **Parent issue with one sub-issue per piece**, so the FBC switch and the RBAC move can be
  reviewed separately.

### Explicit assumptions and trade-offs

These are deliberate and must stay true across all sub-issues:

- **The Go renderer keeps creating the runtime objects at enable time:** Deployment, Service,
  webhook configurations and ConfigMaps. Only RBAC moves to OLM. Component enable and disable
  semantics do not change.
- **Operand ServiceAccounts, Roles, ClusterRoles and bindings exist in the namespace from install
  onward, even while every component is Disabled.** This is the trade-off OADP accepts for the
  non-admin controller. Disabling a component removes its workload, not its RBAC. The README and
  design brief D7 must say so.
- **Operand RBAC can no longer drift from the CSV at runtime.** A component's permissions are
  fixed at install and change only with a WAO upgrade. This is a feature, and it matches a
  standalone OLM install of each operand.
- **`AllNamespaces` install mode promotes CSV `permissions` to ClusterRoles.** OLM copies every
  namespaced Role in the CSV into a ClusterRole and appends get/list/watch on `namespaces`
  (README deviation 8). With operand Roles in the CSV more Roles go through that promotion.
  Harmless for leader-election roles, but it must be documented. `DEV_OLM_INSTALL_MODE` is the
  override in the shared dev targets.
- **`--extra-service-accounts` is a coupling point.** A ServiceAccount missing from that list
  silently turns its Roles into dozens of standalone bundle files. The verify target guards it.

### Sub-issues, in merge order

1. Operand discovery and sync tooling (`update-release-set`, `update-operand-manifests`,
   `verify-operand-manifests`).
2. Replace the ConfigMap-backed dev catalog with an FBC image. Must merge before 3, because the
   standalone ClusterRoles break the ConfigMap catalog.
3. Move operand RBAC from runtime creation to the WAO CSV via OLM.
4. Remove the Python pipeline.

### Out of scope

- Changing which objects the controller renders at runtime, or how enable and disable work.
- Changing component webhook `failurePolicy`, image pinning policy or any public API field.
- Python outside the manifest pipeline (`test/e2e/run.py`, `hack/build_test.py`,
  `hack/e2e_runner_test.py`). Decide separately once the pipeline Python is gone.
- OLM v1 support beyond what FBC already gives us. Tracked in `OLM_V1_READINESS.md`.

### Definition of done

- A developer bumps all six operands with `make update-release-set update-operand-manifests`,
  reviews the diff, commits. No Python, no bundle image fetch.
- `make bundle` produces a CSV whose `permissions` and `clusterPermissions` reproduce every
  operand ServiceAccount's rule set, plus the unbound ClusterRoles as standalone bundle files.
- The controller creates no RBAC objects. The union role is gone.
- `make dev-olm-deploy` installs WAO on a Kind or disposable cluster with OLM owning all RBAC.
- The disposable-cluster install flow uses the FBC catalog image.
- `make test`, `make test-offline` and `make verify-operand-manifests` pass in CI with no network
  access to GitHub or quay.io.

---

## Sub-issue 1

**Title:** Operand sync tooling: discover releases, record source commits, copy manifests from checkouts

Part of #12.

### Goal

Replace `hack/fetch-bundles.py` and `hack/extract-operand-manifests.py` with Make targets that
copy operand manifests from a git checkout, following OADP's `update-non-admin-manifests`.

### Targets

**`make update-release-set`** (network, developer only)

For each component in `release-set.yaml`:

1. Resolve the tag. Default: `tag_name` from
   `https://api.github.com/repos/medik8s/<repo>/releases/latest`. Overrides: `OPERAND_TAG=<tag>`
   for all components, `<COMPONENT>_TAG=<tag>` for one. `latest` is a valid tag and selects the
   post-submit main build.
2. Resolve each operand image `<repo>:<tag>` to a digest with `skopeo inspect`.
3. Copy the image to a directory with `skopeo copy`, extract the Go binary from its layers, and
   read the embedded commit from the `-ldflags` line of `go version -m`. Do not hardcode the
   binary path; read it from the image config entrypoint or scan the executables found.
4. For components with more than one image (SBR operator and agent), read the commit from each
   and fail if they disagree.
5. Write `version`, `commit`, and each image's `upstream` and `pinned` fields into
   `release-set.yaml` with `yq`. Drop the `bundle` digest field; nothing reads bundle images any
   more. Keep `source` as the repo URL.

**`make update-operand-manifests`** (reads `release-set.yaml` only)

For each component:

1. Locate the checkout: `<COMPONENT>_PATH` if set, else `$(OPERAND_SRC_DIR)/<component>`, default
   `.cache/operands/<component>`. Clone if absent, `git fetch` otherwise, then check out the
   recorded `commit`. `.cache/` is already git-ignored.
2. Copy `config/crd/bases/*.yaml` to `config/operands/<component>/crd/` and the files listed in
   `config/rbac/kustomization.yaml` to `config/operands/<component>/rbac/`, as OADP does. Write a
   wrapper kustomization per component that applies the upstream `namePrefix` and removes
   non-RBAC objects that live in `config/rbac` upstream (the metrics Services), which stay with
   the renderer.
3. Render `config/default` with kustomize, namespace set to the `__WAO_NAMESPACE__` placeholder,
   keep only Deployment, Service, ConfigMap, ValidatingWebhookConfiguration and
   MutatingWebhookConfiguration, apply the shared service-ca webhook component, and write the
   result to the directory the Go renderer embeds. This replaces the Python manifest rewriting.
4. Write `config/operands/<component>/UPSTREAM.yaml` with repo, tag and commit.
5. Sync `RELATED_IMAGE_*` values in `config/manager/manager.yaml` from the `pinned` digests with
   `yq`, as OADP does for `RELATED_IMAGE_NON_ADMIN_CONTROLLER`.
6. Run `make bundle`.

**`make verify-operand-manifests`** (offline, runs in CI)

- Each `UPSTREAM.yaml` matches `release-set.yaml` for tag and commit.
- Each `RELATED_IMAGE_*` value in the manager Deployment equals the matching `pinned` digest.
- Every ServiceAccount under `config/operands/*/rbac/` appears in `--extra-service-accounts`.
- The bundle contains no standalone Role, RoleBinding or ServiceAccount file, and no standalone
  ClusterRole other than the expected unbound set.
- `make bundle` followed by `git diff --exit-code`.

**`make bump-operands`**: `update-release-set` then `update-operand-manifests`, then print the
diff. The one-command developer path.

### Implementation notes

- Discovery is roughly 100 to 150 lines of bash in `hack/`, driven by `curl`, `skopeo`, `tar`,
  `go version -m` and `yq`. The copy step is Make plus `yq` and `sed`. Both are documented in
  `docs/operand-manifests-oadp-approach.md` section 8. If the shell grows, a small Go tool using
  `go-containerregistry` and `debug/buildinfo` with unit tests under `make test` is the fallback.
- The six upstream `namePrefix` values are `node-healthcheck-`, `self-node-remediation-`,
  `sbr-operator-`, `fence-agents-remediation-`, `machine-deletion-remediation-` and
  `node-maintenance-operator-`. The prototype found zero name collisions with them applied.
- Kustomize name references break when RBAC objects are deleted inside the same build, so filter
  by kind after the build, not with `$patch: delete`.
- Upstream Deployments carry no `volumes`, so the webhook cert patch must be a strategic merge,
  not a JSON `add` to `/volumes/-`.

### Acceptance

- `make bump-operands` on a clean tree with the currently pinned versions changes `release-set.yaml`
  only by adding `commit` fields and removing `bundle` fields. CRDs and runtime manifests may
  differ in formatting but not in content (the prototype saw only a leading `---` and one NHC
  label).
- `make update-release-set OPERAND_TAG=latest` records a commit for every component that has no
  tag, and `make update-operand-manifests` checks it out.
- `make verify-operand-manifests` passes offline and fails when any one of its checks is
  violated by hand.
- `.cache/operands/` is never committed.

---

## Sub-issue 2

**Title:** Replace the ConfigMap-backed dev catalog with an FBC image

Part of #12. Must merge before the RBAC sub-issue.

### Goal

Retire `make catalog-configmap`, `hack/configmap-catalog.py` and `dist/wao-poc-catalog.yaml`.
Install WAO from a file-based catalog image in every dev and test flow.

### Why

The ConfigMap-backed CatalogSource (`sourceType: internal`) uses the deprecated SQLite loader,
which accepts only `customResourceDefinitions`, `clusterServiceVersions` and `packages`. It cannot
carry the standalone ClusterRoles the RBAC change ships, which is why `check-bundle.py` rejects
them today. FBC is the only format Red Hat catalogs have used since OpenShift 4.11, the only format
community-operators-prod accepts since February 2025, and the only format OLM v1 serves. Design
brief D6 already named FBC as the long-term direction.

### Scope

- The shared `dev-olm-catalog-build` and `dev-olm-catalog-push` targets in medik8s/tools
  `dev/dev.mk` already build a validated FBC image from the source bundle with `opm init`,
  `opm render` and `opm validate`, and optionally chain a released bundle for upgrade tests. Use
  them. Delete wao_poc's own `catalog-build` and `catalog-push` if they only duplicate the shared
  ones.
- Add a committed CatalogSource (`sourceType: grpc`, `image: $(DEV_OLM_CATALOG_IMAGE)`) and
  Subscription manifest, parameterised the same way the shared targets derive image names from
  `DEV_IMG`, to replace the generated `dist/wao-poc-catalog.yaml`.
- Point the disposable-cluster build step at `dev-olm-catalog-push`, pushing to the on-cluster
  build namespace registry already used for the WAO image.
- Drop the standalone-object rejection from the bundle check. Its only reason was the ConfigMap
  loader.
- Update the README install section and design brief D6.
- `make dev-olm-deploy` is unaffected: `operator-sdk run bundle` already renders the bundle into
  an FBC on the fly and never used the ConfigMap catalog.

### Notes

- `DEV_OLM_RELEASED_BUNDLE_REPOSITORY` defaults to a WAO path on registry.redhat.io that does
  not exist yet. `PREVIOUS_VERSION` must stay empty, or `DEV_OLM_PREVIOUS_BUNDLE_IMAGE` must be
  overridden, until a first release exists.
- The wao_poc Makefile resolves `TOOLS_DIR` to `../tools`, which is not where the medik8s/tools
  checkout usually sits. Document `TOOLS_DIR=<path to medik8s/tools>`.

### Acceptance

- A bundle containing standalone ClusterRoles installs through the FBC catalog on a disposable
  cluster, and the Subscription reaches `AtLatestKnown`.
- `make catalog-configmap` and `dist/wao-poc-catalog.yaml` no longer exist.
- `make dev-olm-deploy` still works on Kind.

---

## Sub-issue 3

**Title:** Move operand RBAC from runtime creation to the WAO CSV, owned by OLM

Part of #12. Depends on the sync tooling and FBC sub-issues.

### Goal

WAO stops creating ServiceAccounts, Roles, ClusterRoles, RoleBindings and ClusterRoleBindings for
components. OLM creates them at install from the WAO bundle, as it does for OADP's non-admin
controller.

### Scope

**Bundle**

- `config/manifests/kustomization.yaml` includes `config/operands/<component>/rbac` for all six
  components and `config/operands/<component>/crd` replaces the Python-written CRDs in
  `config/crd/bases`.
- `BUNDLE_GEN_FLAGS` gains `--extra-service-accounts` with the seven operand ServiceAccounts:
  `node-healthcheck-controller-manager`, `self-node-remediation-controller-manager`,
  `sbr-operator-controller-manager`, `sbr-operator-sbr-agent`,
  `fence-agents-remediation-controller-manager`, `machine-deletion-remediation-controller-manager`,
  `node-maintenance-operator-controller-manager`.
- Expected result, verified in the prototype: one `permissions` and one `clusterPermissions`
  entry per ServiceAccount with rule counts matching upstream (FAR 10/4, MDR 8/3, NHC 17/3,
  NMO 14/3, SBR 17/3, SBR agent 8, SNR 14/2), and twenty standalone ClusterRoles: six
  `metrics-reader`, four `ext-remediation`, SBR admin, editor and viewer.

**Controller and renderer**

- Remove `ServiceAccount`, `Role`, `RoleBinding`, `ClusterRole` and `ClusterRoleBinding` from the
  kinds `internal/operands/render.go` renders and from each component's `ManagedKinds`.
- Remove the runtime namespace rewriting of RBAC subjects (design brief D9). OLM rewrites CSV
  subjects itself.
- Remove the `<serviceaccount>-all-namespaces` ClusterRole logic (README deviation 3 and 8). OLM
  does that promotion for an `AllNamespaces` OperatorGroup.
- Delete `config/rbac/operand_union_role.yaml` and remove it from `config/rbac/kustomization.yaml`.
  Remove the `bind` verb WAO held only to create operand RoleBindings (`config/rbac/role.yaml`).
- Status and conflict reporting: WAO still never adopts foreign objects, but RBAC objects are now
  OLM-owned and must be excluded from the conflict scan.

**Docs**

- README: deviations 2, 3 and 8 become historical; add the new trade-off that operand RBAC exists
  while components are Disabled.
- Design brief D7 and D9: superseded, with a pointer to this issue.
- `docs/operand-manifests-oadp-approach.md` stays as the design record.

### Explicit trade-offs to state in the PR

- Operand SAs and roles exist from install onward, even with every component Disabled.
- Operand permissions change only with a WAO upgrade.
- Under `AllNamespaces` install mode OLM promotes every CSV `permissions` Role to a ClusterRole
  with get/list/watch on `namespaces` appended.

### Acceptance

- `make bundle` output matches the prototype rule counts above, and `operator-sdk bundle
  validate --select-optional suite=operatorframework` passes (this runs inside
  `dev-olm-build-push`).
- After install on a disposable cluster with all components Disabled: the seven ServiceAccounts
  and their bindings exist, no operand Deployment exists.
- Enabling each component in turn reaches the same Ready state as today without WAO creating any
  RBAC object. `kubectl get clusterrole,role,rolebinding,clusterrolebinding -l
  app.kubernetes.io/managed-by=workload-availability-operator` returns nothing.
- The WAO ServiceAccount holds no `bind` verb.
- NMO can list and watch namespaces (the deviation 8 regression test).

---

## Sub-issue 4

**Title:** Remove the Python manifest pipeline

Part of #12. Last to merge.

### Goal

Delete every Python file the manifest pipeline used, its virtualenv plumbing and its tests, once
the sync tooling, FBC catalog and RBAC sub-issues have replaced their callers.

### Scope

| File | Lines | Replaced by |
|---|---|---|
| `hack/fetch-bundles.py` | 91 | `update-release-set` |
| `hack/extract-operand-manifests.py` | 371 | `update-operand-manifests` |
| `hack/extract_operand_manifests_test.py` | 256 | `verify-operand-manifests` and Go renderer tests |
| `hack/check-bundle.py` | 76 | `verify-operand-manifests` |
| `hack/configmap-catalog.py` | 38 | FBC catalog |
| `hack/configmap_catalog_test.py` | 37 | deleted with it |

- Delete `hack/requirements.txt`, the `python-env` target, the `.venv` rule, the `PYTHON`
  variable and the `| python-env` order-only prerequisite on `bundles operand-manifests
  operand-manifests-check bundle-check catalog-configmap test-offline`.
- Delete the `bundles`, `operand-manifests`, `operand-manifests-check` and `bundle-check` targets.
- Rewrite `test-offline` so it runs `verify-operand-manifests` and whatever offline checks remain.
  Decide separately whether `hack/build_test.py`, `hack/e2e_runner_test.py` and `test/e2e/run.py`
  move to Go or shell; they are not part of the manifest pipeline and are out of scope here.
- Update `.gitignore` (`__pycache__/`) and README sections that mention the Python tooling.

### Acceptance

- `git grep -l 'python' Makefile hack/` returns only the files intentionally left out of scope.
- `make test` and `make test-offline` pass without a Python interpreter on the PATH.
- A fresh clone can run `make bundle` and `make dev-olm-deploy` with Go, kustomize,
  operator-sdk, yq, skopeo and a container tool only.
