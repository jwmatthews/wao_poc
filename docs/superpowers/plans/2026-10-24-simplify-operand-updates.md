# Simple Operand Configuration Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task after the user approves it. Steps use checkbox (`- [ ]`) syntax for tracking. Execution is inline; no subagents have been requested.

**Goal:** Replace image-derived operand updates with OADP-style local configuration copies and explicit image tags, using a familiar per-operand config/overlays layout.

**Architecture:** `operands.yaml` is the sole developer selection input. Thin per-operand Make targets call one local-copy helper; a shared image validator and image-setting synchronizer keep selected references aligned. Offline rendering and existing bundle generation remain later steps, and supported Make builds render copied content before compilation.

**Tech Stack:** GNU Make, Bash, Git branch/root queries, filesystem copying, Mike Farah yq v4, jq, Kustomize, and the existing Go test suite. No new language, package, registry client, or cluster dependency.

**Spec:** [Simple operand configuration updates](../specs/2026-10-24-simplify-operand-updates-design.md)

**Status:** Approved for implementation on 2026-10-24. Execution is on the existing feature branch, preserving unrelated untracked files; final freshness checks will use a clean temporary checkout. The user additionally authorized live validation on their named development cluster; credentials and cluster identifiers remain outside version control.

## Global Constraints

- Do not modify, fork, or rebuild operand operators.
- Use the exact image tags selected in `operands.yaml`; do not resolve image digests or infer source revisions.
- Keep every component Disabled by default; create no remediation policy, request, native config, or node agent during installation.
- Preserve webhook failurePolicy values, ownership/conflict handling, and the absence of public API image overrides.
- Keep bundle generation separate from update commands; preserve current packaging behavior.
- Run no live-cluster commands without current-session authorization naming a disposable cluster and an explicit kubeconfig.
- Use gh for GitHub interactions; all GitHub writes require approval of the specific proposed action.

## Execution preconditions

- [x] Obtain approval of this plan before implementation. Read the spec and the current `AGENTS.md`.
- [ ] Use the existing feature branch after offering worktree isolation; run final clean-tree checks in a temporary checkout. The current checkout contains unrelated untracked files; preserve them in place. Do not remove or stage them to satisfy cleanliness checks.
- [x] Keep the approved planning documents on the feature branch. Run the required `make check` before any local commit, including a planning-document commit. No GitHub write or push is authorized by approval of implementation.
- [x] Record the baseline with `make check`, `make test-offline`, and `go test ./internal/components ./internal/operands -count=1`. Install existing local build tools through their existing Make targets if needed. Stop on a pre-existing failure and report it before attributing it to these changes.
- [ ] Make the three implementation commits below separately. Do not sync the user's real operand checkouts as part of migration or validation; use temporary local fixtures for source-copy tests.

## File responsibilities and final interfaces

| File or directory | Responsibility |
| --- | --- |
| `operands.yaml` | Six source checkout paths/expected branches; eight independent image repositories/tags and existing Kustomize image selectors |
| `config/operands/<key>/config/` | Complete copied upstream config tree |
| `config/operands/<key>/overlays/{rbac,runtime}/` | WAO-owned adjustments preserved by every copy |
| `config/operands/crd/kustomization.yaml` | Maintained six-entry CRD aggregation |
| `hack/update-operand-manifests.sh [keys...]` | Validate selected local sources, stage/copy config, then synchronize selected image settings; no arguments means all six |
| `hack/operand-image-refs.sh [keys...]` | Offline input/destination validation; stdout sorted `ENV<TAB>repository:tag`; errors on stderr |
| `hack/sync-operand-images.sh [keys...]` | Update selected manager, Kustomize, SNR, and SBR image settings using the shared validator |
| `hack/generate-image-bindings.sh` | Generate the Go matching-reference map from validated records |
| `hack/verify-operand-manifests.sh` | Generated consistency and existing RBAC/bundle-shape checks; no source-checkout requirement or bundle generation mode |
| `Makefile` | Visible per-operand copy targets, one aggregate copy target, offline rendering, and ordered build preparation |
| `test/offline/` | Isolated local-source, tag-validation, generation, and build-order regression tests |

All helpers use WAO's repository-root `operands.yaml`. Keep existing tool-path overrides; add no alternative input-file mode or image/source override environment variables.

## Task 1: Move copied configuration and WAO overlays without changing behavior

**Deliverable:** A working repository with the approved layout, while the legacy selection schema and update commands still work for this intermediate commit.

**Files:**

- Move all six `config/operands/<key>/vendored/config/` directories to `config/operands/<key>/config/`.
- Move all six `config/operands/<key>/rbac/` directories to `config/operands/<key>/overlays/rbac/`.
- Move all six `config/operands/<key>/runtime/` directories to `config/operands/<key>/overlays/runtime/`.
- Modify `config/operands/crd/kustomization.yaml`, `config/manifests/kustomization.yaml`, `Makefile`, `hack/update-operand-manifests.sh`, and `hack/verify-operand-manifests.sh` for those paths.
- Modify `internal/controller/suite_test.go` operand CRD paths, path-sensitive cases in `test/offline/pipeline_test.go`, and active README path descriptions.
- Keep the six `VENDORED.yaml` stamps temporarily because the legacy schema is removed atomically in Task 2.

**Interfaces:**

- Consumes: existing `release-set.yaml`, copied upstream content, and working generation/tests.
- Produces: `config/operands/<key>/config/` and `overlays/` paths with identical manifest behavior.

- [x] **Step 1: Record the behavior-preserving baseline.** Run the focused Go tests and save the current generated files in temporary storage for byte comparison after rendering. Include `internal/operands/manifests`, `internal/components/zz_generated.images.go`, `config/manager/manager.yaml`, and `bundle/`.

```sh
go test ./internal/components ./internal/operands -count=1
```

- [x] **Step 2: Move directories using Git-aware moves; copy no external source.** Repeat the following for the literal keys `nhc snr sbr far mdr nmo`:

```sh
mkdir -p config/operands/nhc/overlays
git mv config/operands/nhc/vendored/config config/operands/nhc/config
git mv config/operands/nhc/rbac config/operands/nhc/overlays/rbac
git mv config/operands/nhc/runtime config/operands/nhc/overlays/runtime
```

- [x] **Step 3: Adjust references by their new relative locations.** Use these exact transformations; do not perform a blind repository-wide string substitution:

```text
runtime resources: ../vendored/config/default       -> ../../config/default
NHC resources:     ../vendored/config/manifests/ocp -> ../../config/manifests/ocp
RBAC resources:    ../vendored/config/rbac          -> ../../config/rbac
SBR extra role:    ../vendored/config/rbac/sbr_agent_privileged_scc_role.yaml
                   -> ../../config/rbac/sbr_agent_privileged_scc_role.yaml
CSV inputs:        ../operands/<key>/rbac           -> ../operands/<key>/overlays/rbac
CRD inputs:        ../<key>/vendored/config/crd     -> ../<key>/config/crd
```

The updater's replacement destination becomes `config/operands/$k/config`. Existing stamp verification must expect runtime `resources[0]` to equal `../../$overlay`, because the legacy overlay field already begins with `config/`. The controller suite path becomes `filepath.Join("..", "..", "config", "operands", k, "config", "crd", "bases")`.

- [x] **Step 4: Render and compare behavior.** Run `make operand-manifests`, then `make verify-operand-manifests test-offline` and the focused Go tests. Expect the saved embedded manifests, image binding values, manager image settings, and bundle files to remain byte-identical. The CRD aggregation paths and explanatory comments are expected to change. Ensure the SBR RBAC wrapper still builds with `--load-restrictor LoadRestrictionsNone`.
- [x] **Step 5: Update active layout documentation and commit.** Explain copied `config/` and WAO-owned `overlays/`; leave historical designs untouched. Run `make check`, stage only Task 1 files, and commit as `operands: separate copied config from WAO overlays`.

## Task 2: Replace discovery with YAML-driven local copies and tagged image settings

**Deliverable:** Per-operand and aggregate update commands that copy local working-tree config, synchronize explicit tags, and stop. The old discovery workflow and metadata are removed, and offline generation consumes the new YAML.

**Files:**

- Replace `release-set.yaml` with `operands.yaml`.
- Rewrite `hack/update-operand-manifests.sh` and simplify `hack/operand-image-refs.sh`.
- Create `hack/sync-operand-images.sh`.
- Adapt `hack/generate-image-bindings.sh`, `hack/verify-operand-manifests.sh`, and the operand section of `Makefile`.
- Delete `hack/update-release-set.sh`, `hack/image-commit.sh`, and all six `config/operands/<key>/VENDORED.yaml` files.
- Keep the CRD aggregation as maintained YAML rather than generating the same fixed list.
- Modify `internal/components/component.go`, `internal/components/components_test.go`, and generated binding comments for the new input contract.
- Modify `test/offline/pipeline_test.go` and `test/offline/doc.go`; replace `test/offline/pull_refs_test.go` with `test/offline/image_refs_test.go`; create `test/offline/source_sync_test.go`.
- Update active `README.md`, `AGENTS.md`, manager comments, and overlay comments in the same commit.

**Interfaces:**

- Consumes: Task 1 layout and the schema/command contracts in the spec.
- Produces: seven visible copy targets, the three shared helper interfaces in the responsibility table, and generation from `operands.yaml` without any external source checkout.

- [x] **Step 1: Adapt fixture loading and write failing contract tests.** Prepare the new YAML input using the exact migration rules in Step 3, while retaining the legacy input until the replacement is complete. Adapt the old tests to the new contract so the test package compiles before checking behavioral failures. Replace the fixture reader/writer with the following implementations and include `operands.yaml` in `newTree`:

```go
type operandInputs struct {
    Operands map[string]map[string]any `json:"operands"`
}

func (tr *tree) loadOperands() operandInputs {
    tr.t.Helper()
    var inputs operandInputs
    if err := yaml.Unmarshal(tr.read("operands.yaml"), &inputs); err != nil {
        tr.t.Fatal(err)
    }
    return inputs
}

func (tr *tree) saveOperands(inputs operandInputs) {
    tr.t.Helper()
    data, err := json.Marshal(inputs)
    if err != nil {
        tr.t.Fatal(err)
    }
    tr.write("operands.yaml", data)
}
```

Keep the existing `tree` methods `run`, `try`, `path`, `read`, and `write`. Fixtures must use temporary Git repositories and never the developer's real operand checkouts. Add this source fixture helper:

```go
func (tr *tree) sourceFixture(key string) string {
    tr.t.Helper()
    relative := filepath.Join("source checkouts", key)
    source := tr.path(relative)
    tr.run("git", "init", "-q", "--initial-branch=main", source)
    if err := os.MkdirAll(filepath.Join(source, "config"), 0o755); err != nil {
        tr.t.Fatal(err)
    }
    tr.write(filepath.Join(relative, "config", "working.yaml"), []byte("working-tree change\n"))
    inputs := tr.loadOperands()
    inputs.Operands[key]["source"] = map[string]any{"path": relative, "branch": "main"}
    tr.saveOperands(inputs)
    return source
}
```

This fixture intentionally has no commits and a path containing spaces. Copying must work without resolving a source commit.

```go
func TestUpdateCopiesWorkingTreeAndPreservesOverlays(t *testing.T) {
    tr := newTree(t)
    source := tr.sourceFixture("nhc")
    overlay := "config/operands/nhc/overlays/runtime/kustomization.yaml"
    before := string(tr.read(overlay))
    tr.write("config/operands/nhc/config/stale.yaml", []byte("removed upstream\n"))
    tr.run("make", "-s", "update-nhc-manifests")
    if got := string(tr.read("config/operands/nhc/config/working.yaml")); got != "working-tree change\n" {
        t.Fatalf("copied content = %q", got)
    }
    if _, err := os.Stat(tr.path("config/operands/nhc/config/stale.yaml")); !os.IsNotExist(err) {
        t.Fatalf("stale file retained: %v", err)
    }
    if got := string(tr.read(overlay)); got != before {
        t.Fatal("copy changed overlay with unchanged image selections")
    }
    if _, err := os.Stat(filepath.Join(source, "config", "working.yaml")); err != nil {
        t.Fatalf("source was changed: %v", err)
    }
}

func TestUpdateRejectsBranchMismatchBeforeReplacingConfig(t *testing.T) {
    tr := newTree(t)
    source := tr.sourceFixture("nhc")
    tr.run("git", "-C", source, "symbolic-ref", "HEAD", "refs/heads/other")
    sentinel := "config/operands/nhc/config/sentinel.yaml"
    tr.write(sentinel, []byte("keep\n"))
    out, err := tr.try("make", "-s", "update-nhc-manifests")
    if err == nil || !strings.Contains(out, "nhc") || !strings.Contains(out, "main") {
        t.Fatalf("branch mismatch diagnostic: %v\n%s", err, out)
    }
    if got := string(tr.read(sentinel)); got != "keep\n" {
        t.Fatal("failed preflight replaced copied config")
    }
}
```

- [x] **Step 2: Add the other meaningful source-copy cases.** Use table-driven cases with these exact setups and outcomes:

| Case | Fixture action | Required outcome |
| --- | --- | --- |
| Missing checkout | Set nhc source.path to `missing-checkout` | Error names nhc/path; copied config and manager settings unchanged |
| Missing config | Remove the fixture source's config directory | Error names nhc/config; destination unchanged |
| Detached HEAD | Commit only fixture content with local `-c user.name`/`-c user.email`, then detach HEAD | Error names nhc/expected branch; destination unchanged |
| Source overlap | Point nhc at the temporary WAO fixture root and use its actual branch name | Error before removing or copying anything |
| Unknown key | Invoke `bash hack/update-operand-manifests.sh unknown` | Nonzero exit naming unknown; no files changed |
| Missing image destination | Remove a selected manager image env or overlay selector | Error before copying config or changing any image setting |
| One operand only | Snapshot snr/config, all generated manifests/bindings, bundle/, and operands.yaml before nhc update | All snapshots unchanged |
| All operands | Create six source fixtures and run `make -j4 update-operand-manifests` | All six copied once, in declared operand order, with consistent manager values |
| No hidden work | Place failing `skopeo`, `curl`, `kustomize`, `go`, and `operator-sdk` commands ahead of PATH after fixture creation | Copy target still succeeds using cached yq; generated manifests/bindings and bundle unchanged |
| Git worktree | Create a temporary fixture worktree on the expected branch | Copy succeeds even though `.git` is a file |

Run focused new source tests before implementation and observe failures caused by the absent targets/new contract, not a missing tool or test compilation error.

- [x] **Step 3: Define and migrate YAML without contacting upstream.** Follow the spec's complete field contract. The initial paths are the six sibling defaults and branches are `main`. For each old image, split its existing `tagged` value at the final colon into `repository` and `tag`, preserve `kustomizeName` where present, and remove all old metadata. Since the committed inputs are all `:latest`, all eight deployed references remain unchanged. Do not run the old updater. Do not copy a real operand checkout during migration.

- [x] **Step 4: Implement the shared image validator and synchronizer.** The validator must reject missing/duplicate known image variables, empty source fields, invalid repository/tag fields, and missing selected image destinations. Validate everything before emitting records or mutating files. Preserve registry-port support; tags such as `wao`, `latest`, `v0.12.0`, and literal `release` have ordinary tag semantics.

The synchronizer reads `repository`, `tag`, and `kustomizeName` (required for the seven container-image entries, omitted for the SBR agent). Use yq's `strenv` instead of interpolating YAML values into query syntax. The Kustomize update has this form:

```sh
WAO_IMAGE_NAME="$name" WAO_IMAGE_REPOSITORY="$repository" WAO_IMAGE_TAG="$tag" \
  "$YQ" -i '(.images[] | select(.name == strenv(WAO_IMAGE_NAME))) |=
    (.newName = strenv(WAO_IMAGE_REPOSITORY) | .newTag = strenv(WAO_IMAGE_TAG))' "$runtime/kustomization.yaml"
```

Set each selected manager `RELATED_IMAGE_*` to the composed reference. Set SNR `SELF_NODE_REMEDIATION_IMAGE` from its manager reference and SBR `RELATED_IMAGE_AGENT` from its agent reference. Require exactly one matching destination before writing; preserve unrelated fields and image entries. Skip writing when the selected values already match, so an unchanged image selection does not reformat the overlay or manager configuration. Validate all selected destinations through the shared reference helper before the updater copies anything.

- [x] **Step 5: Implement the local copy helper and thin Make targets.** Resolve source paths relative to WAO's root or accept absolute paths. Check the Git root and symbolic branch without reading a commit. Use a staging directory to preserve the existing destination if copying fails:

```sh
actual_branch=$(git -C "$source" symbolic-ref --quiet --short HEAD) || {
  echo "$key: checkout must be on branch $expected_branch" >&2; exit 1;
}
[ "$actual_branch" = "$expected_branch" ] || {
  echo "$key: expected branch $expected_branch, found $actual_branch" >&2; exit 1;
}
cp -R "$source/config" "$work/$key"
# After all selected sources and image destinations have passed preflight,
# replace only the fixed config/operands/$key/config destination.
```

Check source/destination overlap before staging. Support spaces through quoted arguments. Copy files directly; remove stale destination content by replacing the directory. End by calling `hack/sync-operand-images.sh` with the selected keys. Do not call Make, rendering, tests, or bundle generation from this helper.

For an empty argument list use the fixed order `nhc snr sbr far mdr nmo`; reject keys outside that set before building any destination path. Expose the exact targets in the spec. Use one shared recipe for the six explicit per-operand target names, and one aggregate recipe calling the helper without arguments. Do not make the aggregate depend on six concurrently runnable recipes that all edit manager.yaml.

- [x] **Step 6: Adapt offline generation and its existing tests.** `operand-manifests` calls the synchronizer, generates Go image bindings from `ENV<TAB>reference` records, builds the runtime overlays, and filters the same five runtime kinds. Remove image-update shell duplication from the Make recipe and stop generating the static CRD list. Remove YAML overlay/stamp consistency checks; verify that the actual referenced copied directories exist and are buildable. Keep NHC's required OCP packaging assertions and the SBR RBAC assertions.

In `internal/components/components_test.go`, read `operands.yaml` and compare each `ImageBinding.Original` to `Repository + ":" + Tag`. Update tag-change tests to edit each image's tag independently; retain stale-binding rejection, failure-without-overwriting-generated-bindings, unstaged-generation acceptance, and required NHC client-CA permissions.

Replace the old digest-policy test cases with this explicit validation set:

```text
accept: latest; wao; v0.12.0; different manager/console tags; registry:5000/path
reject: missing repository; missing tag; repository containing @sha256;
        tag containing whitespace or colon; duplicate/missing required image env;
        missing selected manager env; missing selected Kustomize selector
```

Keep runtime-renderer tests that use digest references as supplied environment values: this helper's tag-only input policy does not remove the renderer's general ability to substitute a reference supplied by another packaging flow. Do not change runtime pull policies in this task.

- [x] **Step 7: Remove obsolete paths, commands, modes, and tests.** Delete the two discovery scripts, all stamps, the old YAML, `bump-operands`, `update-release-set`, old source/tag override variables, `SKIP_RENDER`, and the optional `VERIFY_BUNDLE` generation mode. Delete resolver tests and replace the retired bump-order test with aggregate-source-update behavior. Preserve useful runtime and packaging regression tests. Remove active comments describing commits or digests as the source-selection contract.

- [x] **Step 8: Document and validate the new command boundary.** Update README with YAML editing, per-operand copy, separate `make operand-manifests`, and later `make bundle-reset`. Update `AGENTS.md` image policy to the exact tag contract without changing other constraints. Explain that the expected branch is checked and working-tree edits are included. Explain that source paths are machine-local inputs and may need editing. Document that verification regenerates files in place when checking drift.

Run:

```sh
bash -n hack/update-operand-manifests.sh hack/operand-image-refs.sh hack/sync-operand-images.sh hack/generate-image-bindings.sh hack/verify-operand-manifests.sh
make operand-manifests
make verify-operand-manifests test-offline
go test ./internal/components ./internal/operands -count=1
make check
```

Expect all checks to pass without the actual source checkout paths existing. Review generated reference values and confirm they remain the eight original `:latest` strings. Stage only Task 2 files and commit as `operands: sync local config from explicit YAML inputs`.

## Task 3: Make later build preparation reliable and complete migration validation

**Deliverable:** Supported Make builds prepare embedded manifests, while source updates and bundle generation retain separate boundaries. Developer documentation reflects the complete workflow.

**Files:**

- Modify `Makefile` manager/run/docker-build paths and the shared-dev include integration.
- Create `test/offline/build_preparation_test.go` using the existing temporary tree harness.
- Finalize `README.md`, active Make help text, and relevant script comments.
- The Dockerfile and shared tools repository remain unchanged; direct container builds consume prepared generated files.

**Interfaces:**

- Consumes: offline `make operand-manifests` that never reads local source checkouts.
- Produces: ordering guarantees for `make manager`, `make run`, `make docker-build`, and shared `make dev-build`, including parallel Make.

- [x] **Step 1: Write failing ordering tests with stub generators/builders.** In the fixture override only the `operand-manifests` generation recipe with one that writes a completion marker. Stub `hack/build.sh`, `go run`, and the container-tool command so each fails unless that marker exists. Stub unrelated `generate`, `fmt`, `vet`, `manifests`, and `test-no-verify-changes` work through a test-only supplemental Makefile, and let harmless Make parse-time `go env` queries delegate to the real Go binary. Preserve the actual build-target recipes and prerequisites under test; replacing the manager/run/docker-build recipes would bypass the ordering being tested. Exercise `make -j4 manager`, `make -j4 run`, `make -j4 docker-build`, and a fixture `dev-build`. Do not launch a manager, container engine, or cluster. Use this marker assertion in the substituted build recipe:

```sh
test -f .operand-generation-complete || {
  echo 'build started before operand generation' >&2; exit 1;
}
```

The generator stub must not finish immediately; use the existing test suite's short ordering-delay pattern so an incorrect prerequisite-only parallel implementation is observable. Also add a generator-failure case asserting that no compile/container marker is created.

- [x] **Step 2: Wire sequential build preparation.** Explicitly finish operand generation before invoking prerequisite commands that may compile or load Go packages. A manager recipe can take this form:

```make
manager:
	$(MAKE) operand-manifests
	$(MAKE) generate fmt vet
	./hack/build.sh ./bin
```

Apply the same ordering to run and docker-build while retaining their existing normal preparation steps. Keep generation outside the copy helper and keep source sync outside every build target. Avoid recursion back from generation into a build target.

- [x] **Step 3: Integrate the shared dev build without changing shared tools.** Add an extra prerequisite only when the existing dev Makefile has been loaded:

```make
ifneq ($(wildcard $(DEV_MK)),)
dev-build: operand-manifests
endif
```

Place this after the shared include. The shared dev-build recipe performs its container operation after prerequisites; it does not require operand source checkouts. When tools are absent, leave `dev-build` to the existing lazy `dev-%` rule so it can clone the tools and re-enter Make normally. Test both Makefile states using local fixture includes and a stub fallback; the tests must make no network requests. Do not exercise real `dev-olm-deploy` or any push/install recipe.

- [x] **Step 4: Finish the short developer instructions.** Lead with this three-stage sequence:

```sh
# Edit operands.yaml source paths/branches and image repositories/tags.
make update-nhc-manifests

# Prepare runtime objects and image bindings for the WAO binary.
make operand-manifests

# Generate normalized bundle content when ready for packaging.
make bundle-reset
```

Document that supported Make builds perform the middle step automatically. Document the middle step explicitly before direct `podman build`/`docker build`. Keep Kubernetes/OpenShift selection in later overlays/packaging; do not claim this change implements a generic Kubernetes bundle or certificate solution.

- [ ] **Step 5: Run integration checks and commit.** Run the new build-order tests, `make check`, `make test-offline`, and focused component/operand tests. Separately run `make bundle-reset` and inspect its diff; expect no bundle behavior changes from path/schema migration with preserved image references. Stage only Task 3 files and any justified generated normalization, then commit as `build: prepare operand manifests before compiling WAO`.

- [ ] **Step 6: Run final required checks on the clean implementation checkout.** After commits, ensure `git status --short` is empty. Run `make test-offline` and `make test` as required by `AGENTS.md`, then inspect `git status --short` again. If generation exposes real drift, review and fix it, run `make check`, commit that focused correction, and repeat the affected checks on the resulting clean tree. Do not remove unrelated files or weaken freshness checks to force a pass.

## Final review checklist

- [ ] All six copy targets are discoverable through `make help`; the aggregate is the only all-operand entry point.
- [ ] Copied config is replaceable; WAO overlays survive refreshes; no new stamps, lockfiles, compatibility modes, or source/image inference remain.
- [ ] Source copy succeeds before an operand image is published and includes config edits not yet committed.
- [ ] All eight image references are selected independently and used consistently, including NHC console, SNR self image, and SBR agent environment values.
- [ ] Neither copying nor rendering changes `operands.yaml` or generates the bundle; rendering/building requires no operand checkout.
- [ ] NHC OCP configuration, webhook failure policies, SBR agent roles/SCC access, default Disabled state, and foreign-object conflict behavior are preserved.
- [ ] Active code/docs reference the new layout/input; historical docs are unchanged. Search runtime/build paths rather than treating historical mentions or ordinary Go dependency vendoring as obsolete workflow references.
- [ ] No operand repository, shared tools checkout, or GitHub state was changed. Cluster changes are limited to the separately authorized live validation.
- [ ] Present the resulting diff and verification evidence. Any proposed GitHub action is drafted and separately approved before it is performed.

## Execution evidence

- Baseline `make check`, `make test-offline`, and component/operand tests passed.
- The mechanical directory migration preserved embedded runtime objects, generated image
  references, manager configuration, and bundle files byte for byte.
- YAML/local-copy changes passed lint, import, generated consistency, offline fixture,
  component, and renderer tests. All eight initial image tags remain `latest`.
- Build-order tests passed for all four supported paths under parallel Make, including
  generation failure and the lazy shared-tools fallback.
- Separate `make bundle-reset` validation passed without changing bundle content.
- Final clean-checkout checks and the separately authorized live validation are in progress.
  Live-test evidence and credentials are kept outside the repository.
