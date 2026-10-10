# NHC platform integration handoff

Updated 2026-10-10 UTC. Metrics (issue #3) and the console backend (issue #4)
are implemented on branch `node-remediation-console`: `a9c43a6` renders NHC from the
OKD community bundle with the console backend; `3dad6f5` applies the OpenShift metrics
overlay from pinned upstream files; `a0c449d` watches the CA ConfigMap; `2ea29d5`
makes parity assert the platform contract; `d2d987e` and `5730432` add live checks;
`75cd62b` documents the supplements (D11); `9f8b87e` points the bundle at the rebuilt
image; `85793c0` fixes the harness. The work was validated on 2026-10-10 on a
disposable OpenShift 5.0.0-rc.5 cluster: all 19 install cases passed. The browser
check of the console pages is still manual (KI-7). Remaining items are tracked in
[docs/known-issues.md](docs/known-issues.md).

## Start here

Read [AGENTS.md](AGENTS.md), [design brief](docs/design-brief.md),
[operand reference](docs/operands.md), and
[implementation plan](docs/implementation-plan.md). The implementation plan's
opening status is older than the existing implementation; inspect the current
code before deciding what remains.

- [Issue #3: NHC metrics ServiceMonitor rejected: missing OpenShift CA and certificate wiring](https://github.com/jwmatthews/wao_poc/issues/3)
- [Issue #4: NHC console plugin has no backend Deployment or Service](https://github.com/jwmatthews/wao_poc/issues/4)
- [Console packaging guide, adapted to this WAO repository](docs/node-remediation-console-packaging.md)

The working branch during the investigation was `node-remediation-console`.
Commit `152e5db` adapted the console packaging guide; it did not implement a
runtime fix. There are unrelated tracked and untracked changes in this
workspace. Run `git status --short`, preserve them, and stage only task files.

Two additional context documents currently exist as **untracked local files**:
`docs/nhc-platform-detection-agent-context.md` and
`docs/nhc-servicemonitor-rejected.md`. They may be unavailable in a fresh
checkout. The platform-detection guide describes newer upstream code, so check
every behavior against the pinned release before using it as a requirement.

## Confirmed findings

Read-only inspection on the authorized disposable OpenShift 5.0.0-rc.5 cluster
found a healthy NHC manager and WAO reporting `Available` with admission ready.
The installation used classic OLM. No cluster configuration was changed and no
remediation policy or request was created during this investigation.

| Area | Finding | Consequence |
| --- | --- | --- |
| Console registration | NHC created `ConsolePlugin/node-remediation-console-plugin`, targeting `node-healthcheck-node-remediation-console-plugin:9443` in its install namespace. | OpenShift detection and registration work. |
| Console backend | The target Deployment and Service are absent; no backend EndpointSlices or `nrc-plugin-cert` exist. | The registered plugin cannot serve its assets. |
| Console enablement | The plugin is absent from `Console/cluster.spec.plugins`. | Enabling it alone would still leave a broken backend. Preserve other enabled plugins during any future update. |
| Metrics | The packaging lacks the OpenShift CA bundle, metrics Service selection/certificate wiring, and manager metrics certificate mount described in #3. | A running manager does not establish working monitoring. |
| Existing checks | `make operand-manifests-check` and `make bundle-check` passed despite these omissions. | They verify the selected bundle and current contract, which omit the platform additions. |

WAO extracts the published NHC bundle pinned in `release-set.yaml`. That bundle
contains the manager but no console server. The pinned upstream release workflow
uses the Kubernetes packaging target. Both the OCP and OKD source overlays add
the console server; the OCP overlay also adds monitoring and certificate
configuration. NHC's runtime initialization assumes installation supplied those
resources: creating a `ConsolePlugin` does not create its backend.

The complete pinned overlay review found no third independent workload beyond
the console and monitoring additions. It did identify supporting work that must
be considered when implementing them:

- **Namespace and RBAC handling:** the extractor replaces every resource
  namespace with WAO's install namespace, while the renderer rejects other
  namespaces. Blindly importing the OCP overlay would relocate its
  `kube-system` Role/RoleBinding. Preserve fixed namespaces and external
  ServiceAccount subjects where required, or document equivalent existing
  grants. NHC already has effective get/list/watch access to
  `kube-system/extension-apiserver-authentication`; a missing dedicated Role is
  not evidence of a current authorization failure.
- **Prometheus discovery permissions:** the platform Prometheus ServiceAccount
  can get/list/watch Services, Endpoints and Pods in the operand namespace, but
  not EndpointSlices. The inspected Prometheus uses `serviceDiscoveryRole:
  Endpoints`, so the EndpointSlice gap is a parity/upgrade concern, not a proven
  additional cause of the current metrics failure.
- **Ownership and lifecycle:** define ownership of injected CA fields, generated
  serving Secrets, the shared namespace's monitoring label, and NHC-created
  `ServiceMonitor` and `ConsolePlugin` resources. The plugin has no owner
  reference; monitor ownership depends on NHC resolving its manager Deployment.
  Disable, uninstall, restart, and conflict behavior need explicit coverage.
- **Distribution metadata:** OCP packaging also adds a must-gather image and
  downstream product/support metadata. No pinned NHC runtime dependency on
  must-gather was found. Treat diagnostics as a separate decision with its own
  image pin and collection/redaction checks. Do not copy unsupported product,
  subscription, FIPS, or disconnected-operation claims into WAO.
- **Future NHC upgrades:** the newer source includes APIServer TLS-profile
  loading, a profile-change watcher, and associated RBAC. Pinned v0.12.0 lacks
  that behavior. Missing APIServer read permission is therefore not a current
  failure for this image; revisit code and RBAC together on upgrade.

Equivalent platform omissions in the other five operands have **not** been
established. Audit them before claiming complete OpenShift integration.

## Version and source boundaries

Use `release-set.yaml` as the authoritative selection. At investigation time:

| Artifact | Version or immutable reference |
| --- | --- |
| NHC | v0.12.0; source `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f` |
| NHC bundle | `quay.io/medik8s/node-healthcheck-operator-bundle@sha256:2a2ad916a9f827015474b4220b089ba61313112e697d45a50610186b620e1dba` |
| NHC manager | `quay.io/medik8s/node-healthcheck-operator@sha256:5b048ad5d2b8578d2120989a5a822a041d65c985f9ac88d50b000427b32b5391` |
| Console image (pinned in `release-set.yaml`, validated on a disposable cluster) | `quay.io/medik8s/node-remediation-console@sha256:f58fed1feef835bef8ddf9c7ab7edd987b87162866f68d76abd7be47ca737c2d` |
| Matching frontend tag/source | v0.12.0; `d44d9cac99d8ef3af8b8ff59051dfe6a5439600d` |
| Newer NHC context guide | Describes source `f15aa15d7f07f1bca7e2a2a4c05e4c53801c4dd5`, not the pinned manager. |

The console digest was resolved from the published v0.12.0 tag. Image inspection
confirmed linux/amd64 and a plugin manifest declaring version 0.12.0 and
`@console/pluginAPI >=4.16.0-0`. Trusted TLS and asset serving are validated live; browser compatibility is
untested (KI-7). Do not infer frontend source provenance from inherited
nginx image labels or assume current `main` dependencies match this image.

Upstream checkouts are available locally under `~/git/medik8s/`, including
`node-healthcheck-operator` and `node-remediation-console`. Inspect pinned source
with `git show <commit>:<path>`; do not switch or modify their working trees.
Relevant NHC inputs are `config/manifests/{ocp,okd,k8s}/`,
`config/optional/{console-plugin,prometheus-ocp,kube-system-rbac}/`, the Makefile,
and `.github/workflows/release.yaml` at the pinned commit.

## Remaining work

See KI-1 through KI-7 in [docs/known-issues.md](docs/known-issues.md) and the
[design spec](docs/superpowers/specs/2026-10-09-nhc-platform-integration-design.md).

Likely implementation and verification touchpoints:

| Concern | Files |
| --- | --- |
| Selection, extraction, provenance | `release-set.yaml`, `hack/extract-operand-manifests.py`, `hack/extract_operand_manifests_test.py` |
| Image plumbing | `internal/images/`, `config/manager/manager.yaml`, `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml` |
| Component resources and rendering | `internal/components/nhc.go`, `internal/components/components_test.go`, `internal/operands/render.go`, `internal/operands/render_test.go` |
| Reconciliation, readiness, watches | `internal/controller/`, `cmd/main.go` |
| Regenerated artifacts | `internal/operands/manifests/`, `config/rbac/operand_union_role.yaml`, `bundle/` |
| Cluster assertions | `test/cluster/05-enable-nhc.sh`, `test/cluster/parity.py`, related lifecycle checks |

Current parity checks compare against the same selected bundle. Extend their
expected contract so missing platform supplements produce a failure rather than
passing because both inputs omit the resources.

## Validation and working constraints

Implement behavior changes test-first, including a demonstrated failing test.
Run `make test` and `make test-offline` before each small `wao:` commit, plus
`make operand-manifests-check` and `make bundle-check` after packaging changes.
Preserve the configured Git author/committer and append the required Codex
coauthor trailer exactly once.

There is a known local test-environment problem: `make test` invokes
controller-gen with `paths="./..."`, which discovers unrelated Go test source
under ignored `evidence/` and fails on dependencies outside WAO's module.
`make test-offline` passed in the working checkout, and `make test` passed in an
isolated copy of tracked working-tree source with ignored evidence excluded.
Use an isolated source copy for repeatable validation if this recurs; include
the current task's new files. Do not add those foreign dependencies to WAO or
delete someone else's evidence to make tests pass. Report where checks ran.

Preserve these constraints throughout implementation:

- Consume unchanged upstream images pinned by digest; do not fork or rebuild
  component operators or expose a public component-image override.
- All six components remain Disabled by default. Enabling an operand must not
  implicitly create a remediation policy, request, native config, or node agent
  beyond the repository's explicit component lifecycle contract.
- Never change component webhook `failurePolicy`. Never adopt an existing
  object WAO did not create; report conflicts.
- Obtain confirmation of the disposable cluster in the session doing the tests
  and always pass its kubeconfig explicitly. Prior investigation access is not
  a replacement for a new session's confirmation. Keep cluster identifiers and
  credentials out of tracked files, and never capture Secret values.
- Use server-side dry-run for admission tests. Do not run upstream deployment
  shortcuts that create live NHC policies. Do not create real
  `NodeHealthCheck`, `StorageBasedRemediationConfig`, `NodeMaintenance`, or
  remediation requests as part of installation validation.

## Local investigation evidence

Portable findings and acceptance criteria are in issues #3 and #4. Additional
evidence remains git-ignored and may be unavailable in another checkout:

- `evidence/2026-10-10-console-deep-dive-001607/REPORT.md`: console diagnosis.
- `evidence/2026-10-10-console-deep-dive-001607/results.json`: structured checks.
- `evidence/2026-10-10-console-deep-dive-001607/OVERLAY-REVIEW.md`: complete pinned
  overlay review and the distinction between current failures and future risks.
- `evidence/2026-10-10-console-deep-dive-001607/overlay-rbac-summary.json`:
  effective access checks.
- `evidence/2026-10-08-213356-servicemonitor-debug/`: earlier metrics investigation.

Raw command records and the recorder include cluster-specific information. Do
not commit them or copy their contents into public issues. Any additional
published evidence must be sanitized and reviewed under `AGENTS.md`.
