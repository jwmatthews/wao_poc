# Simple operand configuration updates

Status: approved for implementation on 2026-10-24. The user also authorized live testing with their named development kubeconfig (kept outside version control). This design supersedes the earlier image-derived source and digest-selection designs for this development helper.

## Purpose and mental model

WAO copies each operand's `config/` tree and applies its own Kustomize overlays. Refreshing the copy leaves WAO's adjustments intact.

A developer chooses the source checkout, expected branch, image repositories, and image tags in YAML. The update command copies those files and synchronizes image settings. Rendering and bundle generation are separate later actions. The helper trusts the developer's source/image combination.

## Decisions carried forward from the discussion

- Simplify the existing workflow and remove the replaced discovery machinery.
- Follow OADP's visible per-operand update targets and direct file-copy approach.
- Copy each operand's whole `config/` tree, preserving upstream directory relationships.
- Store copied configuration in `config/operands/<key>/config/` and WAO adjustments in `config/operands/<key>/overlays/{rbac,runtime}/`.
- Use local checkout contents, including uncommitted and untracked files under `config/`, with an expected-branch check.
- Keep image tags exactly as selected; derive no source revision or image digest.
- Generate the bundle in a separate packaging step.

## OADP reference

The local OADP `oadp-dev` checkout provides three examples in its Makefile:

| Target | Copy operation | Integration adjustment |
| --- | --- | --- |
| `update-non-admin-manifests` (line 1152) | CRD bases, listed RBAC files, listed samples | One image environment value |
| `update-vmfr-manifests` (line 1173) | CRD bases, listed RBAC files, listed samples | Four image values and an RBAC name prefix |
| `update-kubevirt-datamover-manifests` (line 1201) | Listed RBAC files | One image value and an RBAC name prefix |

These targets read files from the supplied checkout without Git selection or image discovery. They end with `make bundle`; WAO omits that final operation from its update targets. WAO copies more because its runtime manifests come from upstream configuration, whereas these OADP operand Deployments are constructed in Go.

OADP source: `~/git/openshift/oadp-operator/Makefile`. Operand examples: `~/git/migtools/{oadp-non-admin,oadp-vm-file-restore,kubevirt-datamover-controller}`. These paths are investigation references, not runtime dependencies.

## Layout and ownership

```text
operands.yaml
config/
  crd/                                  # WAO CRD and operand CRD aggregation
  rbac/                                 # WAO permissions
  manager/                              # WAO Deployment and selected image values
  operands/
    nhc/
      config/                           # copied NHC config/; refreshed as a unit
      overlays/
        rbac/                           # WAO packaging adjustments
        runtime/                        # WAO workload/webhook adjustments
    snr/ ... sbr/ ... far/ ... mdr/ ... nmo/
    crd/kustomization.yaml              # stable list of copied operand CRD directories
internal/
  components/zz_generated.images.go      # generated image matching references
  operands/manifests/<key>/objects.yaml  # generated runtime objects embedded in Go
```

The update command replaces only the selected operand's `config/` directory and synchronizes its image fields in WAO-owned configuration. It never edits upstream checkouts or replaces WAO overlay directories. Operand samples remain inside the copied tree; the update does not add them to WAO's sample list or apply them to a cluster.

The migration moves existing copied files without refreshing from local checkouts. Existing rendered objects, selected images, API behavior, and bundle content must remain unchanged by the directory move.

## YAML contract

Replace `release-set.yaml` with the developer-maintained `operands.yaml`. Use `operands` as the top-level map and retain the six keys `nhc`, `snr`, `sbr`, `far`, `mdr`, and `nmo`.

```yaml
operands:
  nhc:
    source:
      path: ../node-healthcheck-operator
      branch: main
    images:
      RELATED_IMAGE_NHC_MANAGER:
        repository: quay.io/medik8s/node-healthcheck-operator
        tag: latest
        kustomizeName: quay.io/medik8s/node-healthcheck-operator
      RELATED_IMAGE_NHC_CONSOLE:
        repository: quay.io/medik8s/node-remediation-console
        tag: latest
        kustomizeName: quay.io/medik8s/node-remediation-console
```

Each image has an independent repository and tag. The deployed reference and generated matching reference are both `repository:tag`; neither is stored redundantly. `kustomizeName` retains the existing static selector for an image entry in the runtime overlay. It is integration wiring, not an image override or a discovered value. Require `kustomizeName` for the seven image entries used as container images. The SBR agent omits it because its reference is an environment value in the SBR manager's Deployment.

This small retained selector avoids adding a second mapping file or hardcoding seven upstream image names in a generic script. Developers normally edit `source`, `repository`, and `tag`.

Remove component-level `repo`, `tag`, `commit`, `overlay`, top-level `resolvedAt`, and image-level `tagged`, `pullRef`, and legacy `pinned`. Remove all six `VENDORED.yaml` files without introducing replacement stamps or a lockfile. The selected upstream overlay is already expressed in WAO's Kustomization resources.

Initial source settings use sibling checkout paths and the expected branch `main`:

| Key | Initial source.path | Initial source.branch |
| --- | --- | --- |
| nhc | `../node-healthcheck-operator` | `main` |
| snr | `../self-node-remediation` | `main` |
| sbr | `../storage-based-remediation` | `main` |
| far | `../fence-agents-remediation` | `main` |
| mdr | `../machine-deletion-remediation` | `main` |
| nmo | `../node-maintenance-operator` | `main` |

These are editable checkout-layout defaults, not an inference from image contents. Preserve all eight currently selected `:latest` image references during migration. Do not select a new branch or image tag from the older handoff document. Before a developer's first update, they set paths and branches for their own checkout layout.

## Source-copy contract

`source.path` names an operand repository root. Relative paths resolve from the WAO repository root; absolute paths are also accepted. Shell expansion inside YAML is unsupported: use a repository-relative path or an absolute path rather than `~` or `$VARIABLE`.

For selected operands, verify that the path is a Git repository root, its current symbolic branch equals `source.branch`, and `config/` exists. A Git worktree is supported through Git queries rather than testing whether `.git` is a directory. Missing paths, detached HEAD, and branch mismatch produce operand-specific errors before replacing any selected configuration.

Read the checked-out files directly. Do not call `git archive`, inspect `HEAD` commits, write Git hashes, clone, fetch, pull, checkout, switch, reset, or rebase. A branch-name check verifies only that the checkout is on the requested branch; the helper does not establish correspondence to an image.

Validate all selected operands and image-update destinations before mutation. Stage each copied directory in temporary storage before replacing its fixed destination. Reject a source config path that overlaps the destination. Replacing the directory removes stale files deleted upstream. A later I/O failure may leave earlier operands updated; report the failing operand and allow rerunning. A cross-operand rollback system is outside this helper's scope.

## Command boundaries

| Command | Responsibility | External operand checkout required? |
| --- | --- | --- |
| `make update-nhc-manifests` and the other five per-operand targets | Copy one config tree; synchronize only that operand's manager/overlay image settings | Selected operand only |
| `make update-operand-manifests` | Perform the same updates for all six, sequentially | All six |
| `make operand-manifests` | Synchronize YAML image settings; generate Go bindings and embedded runtime objects from copied config | No |
| `make verify-operand-manifests` | Check generated consistency and existing RBAC/bundle shape | No |
| `make bundle` / `make bundle-reset` | Existing separate bundle generation and normalization | No |

Update targets call no renderer, Go tests, bundle tooling, registry tooling, or cluster tooling. They do not rewrite `operands.yaml`. One shared helper implements copying; the six visible Make targets supply operand keys. The aggregate invokes the helper once for sequential updates, including under parallel Make.

Remove `bump-operands` and `update-release-set` instead of leaving aliases or extra modes. Remove `OPERAND_TAG`, per-operand tag/path overrides, `OPERAND_SRC_DIR`, `RELEASE_SET`, and `SKIP_RENDER`. `operands.yaml` is the sole selection input; existing tool-path settings such as `YQ` and `KUSTOMIZE` remain build settings.

## Small implementation units

- `hack/update-operand-manifests.sh [keys...]`: local source validation and config copying; delegates image-setting synchronization. No arguments selects all operands.
- `hack/operand-image-refs.sh [keys...]`: validates the YAML contract offline and emits sorted `ENV<TAB>repository:tag` records. It checks source field shape but does not require source paths to exist. All eight known image variables must be present exactly once. Tags follow OCI tag syntax; repositories accept registry ports and reject digest/tag suffixes in the repository field. Validate the selected manager image environment entries, Kustomize selectors, and SNR/SBR environment destinations before emitting records, so callers can preflight without a separate command mode.
- `hack/sync-operand-images.sh [keys...]`: uses validated YAML to update manager `RELATED_IMAGE_*`, runtime Kustomize image entries, SNR `SELF_NODE_REMEDIATION_IMAGE`, and SBR `RELATED_IMAGE_AGENT`. The shared image-reference validator supplies preflight; this script updates only selected operands. No arguments selects all operands.
- `hack/generate-image-bindings.sh`: generates matching references from the shared validated image records. No independent image policy or duplicate schema validator.
- `Makefile` `operand-manifests`: retains the short offline render loop and delegates image synchronization. The six-entry CRD aggregation becomes maintained configuration, eliminating generation of a static list.
- `hack/verify-operand-manifests.sh`: adapts to the new schema and paths; removes stamp checks and the `VERIFY_BUNDLE` generation mode. Preserve useful RBAC/bundle checks. Its existing regeneration comparison can update generated files when stale; document that behavior accurately rather than describing it as read-only.

Delete `hack/update-release-set.sh` and `hack/image-commit.sh`. Keep `jq` only where it simplifies the existing shared offline YAML validation; removing registry logic does not require rewriting the entire tool stack.

## Build preparation and packaging

Supported Make build/run paths must render copied content before compiling or starting WAO. Include `manager`, `run`, `docker-build`, and the shared `dev-build` path. Generation reads only committed/copied WAO inputs and never invokes source sync. Use explicit ordering so parallel Make cannot compile while generation is incomplete.

The shared tools `dev-build` recipe invokes the container build directly. Add the generation prerequisite from WAO's Makefile only after the shared dev Makefile is available; preserve the lazy `dev-%` download fallback when it is absent. Do not edit the shared tools repository. Direct container builds continue to consume the generated files in their build context; document `make operand-manifests` as preparation when bypassing Make build targets. The Dockerfile does not need operand checkouts or a source-sync stage.

Retain existing OpenShift integration: webhook service-ca patches, NHC's OCP configuration and console plugin, and SBR SCC/agent RBAC. The same copied config can feed later platform-specific overlays through `MANIFESTS_DIR`. This change does not implement generic Kubernetes certificate handling or claim a distinct Kubernetes bundle; `bundle-k8s` is currently an alias. Future platform differences belong in overlays and packaging targets, outside source-copy logic.

Runtime reconciliation and image pull-policy behavior are unchanged by this work. Current `:latest` handling remains; choosing another tag does not add automatic rollouts, registry polling, or a new pull-policy rule. Agent pod behavior stays controlled by unchanged operand operators.

## Global constraints

- Do not modify, fork, or rebuild operand operators.
- Use the exact image tags selected in `operands.yaml`; do not resolve image digests or infer source revisions.
- Keep every component Disabled by default; create no remediation policy, request, native config, or node agent during installation.
- Preserve webhook failurePolicy values, ownership/conflict handling, and the absence of public API image overrides.
- Keep bundle generation separate from update commands; preserve current packaging behavior.
- Run no live-cluster commands without current-session authorization naming a disposable cluster and an explicit kubeconfig.
- Use gh for GitHub interactions; all GitHub writes require approval of the specific proposed action.

Update the existing image hard constraint in `AGENTS.md` to match this explicitly requested development contract. Do not alter unrelated repository constraints or historical design records.

## Acceptance criteria

1. A developer can explain the workflow as “edit YAML, refresh an operand's config, build/package later.”
2. A single-operand update includes uncommitted config changes, removes stale copied files, preserves overlays and other operands, and updates only its image settings.
3. Update succeeds with no published operand image, registry access, renderer, or bundle generation.
4. Missing checkout/config, branch mismatch, detached HEAD, unknown operand, malformed image settings, and missing image destinations fail with clear diagnostics before updates.
5. All-operand updates are sequential under `make -j`; rendering never requires local operand checkouts.
6. Generation keeps all eight tagged images aligned across manager settings, overlays, environment patches, Go bindings, and runtime objects.
7. The layout migration preserves rendered runtime behavior and bundle contents; NHC and SBR integration checks remain effective.
8. Existing component, operand, offline, lint/import, controller/envtest, and bundle-freshness checks pass using the repository's required workflow.
9. Active code and README no longer direct developers to release discovery, hashes, old path overrides, provenance stamps, or the retired bump target.
