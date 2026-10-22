# Operand pull references implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan inline, task by task. Steps use checkboxes for tracking. Do not start implementation merely because this plan exists; the current request is planning.

**Goal:** Make latest operand selections deploy `:latest`, while all other tags remain pinned to digests.

**Architecture:** Replace `images.<ENV>.pinned` with `pullRef` in the release set. A shared offline validator enforces the latest-versus-digest contract and supplies references to generation and verification. Keep tagged image matching and source-commit vendoring, and explicitly set the pull policy for configured latest Deployment containers.

**Tech stack:** Bash, GNU Make, yq v4.53.2, jq, skopeo, kustomize v5.8.1, Go 1.24, Kubernetes API v0.33.0, and the existing operator-sdk bundle targets. No new dependencies.

**Design:** [Operand image pull references](../specs/2026-10-21-operand-pull-refs-design.md).

## Working rules

- Inspect the current tree before editing. Do not modify component source under `vendored/`.
- Keep the change local; do not deploy, push, or refresh published images as part of offline validation.
- Use isolated temporary Git trees for tests that regenerate artifacts. The current baseline manager uses latest while the generator still requires digests, so baseline verification may report and rewrite manager references.
- Run `make check` before each commit. Preserve configured author and committer identities and append `Co-authored-by: Codex <noreply@openai.com>` exactly once, separated by a blank line.
- Keep the schema, readers, writers, fixtures, and committed generated outputs in one coherent integration commit rather than committing a broken migration halfway through. Pull-policy handling can be a separate commit with its tests.
- Before pushing, run `make test-offline` and `make test` on a clean tree. These use local tests and envtest, not a live cluster.

## File responsibilities

| File | Change |
| --- | --- |
| `release-set.yaml` | Replace `pinned` with `pullRef`; document the policy |
| `hack/operand-image-refs.sh` (new) | Validate all selected references offline and emit tab-separated environment names and references |
| `hack/update-release-set.sh` | Select floating latest or digest; extract release commits through the resolved digest |
| `Makefile` | Generate `RELATED_IMAGE_*` from validated pull references; clarify selector help |
| `hack/verify-operand-manifests.sh` | Compare manager values with validated pull references |
| `test/offline/pull_refs_test.go` (new) | Reference validation, resolver stubs, migration, mixed selection, generation, and verification tests |
| `test/offline/pipeline_test.go` | Update the existing tag-changing fixture to produce consistent pull references |
| `internal/operands/render.go` | Explicit Always policy for configured latest Deployment images |
| `internal/operands/render_test.go` | Actual rendered image and policy assertions |
| `internal/operands/pull_policy_test.go` (new) | Internal-package helper tests for explicit existing policies, init containers, and unrelated images |
| `AGENTS.md`, `README.md`, `config/manager/manager.yaml` comments | Describe latest and digest rules |
| `hack/generate-image-bindings.sh`, `internal/images/images.go`, `api/v1alpha1/workloadavailabilityconfig_types.go` comments | Replace inaccurate universal pinning descriptions |
| Generated runtime, CRD, manager, and bundle files | Regenerate using existing targets; include only resulting changes |

## Task 1: Shared reference contract and schema migration

- [ ] Add tests using the existing `newTree`, `loadReleaseSet`, and `saveReleaseSet` helpers in `test/offline`. Each test starts from a migrated fixture: latest gets `pullRef = tagged`; other tags get the existing digest; delete `pinned`.
- [ ] Cover these valid cases: all latest, all release digests, and one release component with the others latest. Cover these invalid cases: missing/empty `pullRef`, latest with a digest, non-latest with a tag, malformed SHA-256, mismatched repository, `tagged` inconsistent with component tag, duplicate environment names, and a remaining legacy `pinned` field. Assert that errors identify the offending component/image and generation does not update manager values after a reference validation error.
- [ ] Run the new contract tests and confirm failure before implementing the helper:

```sh
go test ./test/offline -run 'TestPullRef' -count=1
```

- [ ] Create executable `hack/operand-image-refs.sh`. Follow the existing scripts' Git-root handling, `RELEASE_SET` override, and yq lookup. Read all components and images, enforce the design contract, and collect output in a temporary file. Print output only after every entry validates. Emit one `ENV<TAB>pullRef` record per image; emit diagnostics only on stderr. Use Bash comparison for `latest`, string equality for tagged/latest references, and `^sha256:[0-9a-f]{64}$` for the digest suffix after checking the repository separately. Reject duplicate names and old `pinned` fields.
- [ ] Migrate committed YAML entries without network access. Preserve component commits and `resolvedAt`. Change the existing `changeTags` fixture so every synthetic release tag has a valid same-repository digest even when the repository baseline was latest.
- [ ] Replace Make's digest-only loop with a complete validation capture followed by its existing environment-variable update loop. The important shell ordering is:

```sh
refs=$(YQ="$YQ" hack/operand-image-refs.sh)
while IFS=$'\t' read -r env img; do
  cur=$("$YQ" "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$env\") | .value" config/manager/manager.yaml | grep . || echo __MISSING__)
  if [ "$cur" = __MISSING__ ]; then
    echo "operand-manifests: $env not found in config/manager/manager.yaml" >&2
    exit 1
  fi
  if [ "$cur" != "$img" ]; then
    "$YQ" -i "(select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$env\") | .value) = \"$img\"" config/manager/manager.yaml
  fi
done <<< "$refs"
```

In the Make recipe, double shell dollar signs and retain line continuations so validation and updates run in the same shell under `set -e`. Validate before any manager environment updates; do not run the helper through process substitution, which can hide its failure.

- [ ] Make verification call the same helper and compare each manager environment value against the emitted reference. Replace messages about universal digest pinning with `pullRef` consistency messages.
- [ ] Run contract tests and existing pipeline tests:

```sh
go test ./test/offline -count=1
```

Expected: all reference validation cases and existing generation/verification regressions pass. Resolver tests are introduced in Task 2.

## Task 2: Published-image resolution and tag selectors

- [ ] Add table-driven offline resolver tests. Reduce a temporary release set to NHC so manager and console are exercised together. Replace its temporary `hack/image-commit.sh` with an executable stub emitting a fixed 40-character hexadecimal commit. Put executable fake `skopeo` and `curl` commands ahead of the normal PATH and log their arguments. Fake skopeo emits a fixed raw manifest; fake curl emits a GitHub release response with `tag_name: v9.8.0`. Invoke the real resolver with `env` and explicit selectors so no inherited operand variables influence the result.
- [ ] Assert the selector matrix: default Make latest; standalone resolver default release; explicit latest; explicit release; explicit version tag; `pinned` with a current latest tag; `pinned` with a release tag; and a component override taking precedence. For latest assert no separate digest lookup and that commit extraction uses the tag. For releases assert a SHA-256 reference and extraction through that reference. Start with stale `pinned` data and assert its removal.
- [ ] Add failure cases for image extraction errors, no embedded commit across images, and conflicting embedded commits. Verify each stops the resolver and does not claim a successful completed update. The resolver's existing partial-write behavior is unchanged; making the entire network refresh transactional is outside scope.
- [ ] Run the new resolver tests and observe the old digest-only behavior failing:

```sh
go test ./test/offline -run 'TestResolvePullRef' -count=1
```

- [ ] After resolving special tag selectors, replace unconditional digest resolution with:

```bash
if [ "$tag" = latest ]; then
  pull_ref=$tagged
else
  pull_ref=$(digest_ref "$tagged")
fi
```

Pass `"$pull_ref"` to `hack/image-commit.sh`. Preserve exit-code handling, component commit agreement, and the requirement that at least one image embeds a commit.

- [ ] Write `tagged` and `pullRef`, delete the old field, and show the selected deployed reference in progress output. The YAML assignment becomes:

```bash
"$YQ" -i ".components.$k.images.$env.tagged = \"$tagged\" | .components.$k.images.$env.pullRef = \"$pull_ref\" | del(.components.$k.images.$env.pinned)" "$RS"
```

- [ ] Run the resolver tests and the full offline package. Expected: selectors and failures behave as specified without network calls.

## Task 3: Latest image startup behavior

- [ ] Add rendered-output tests across every component, using the existing `testImages` helper and renderer. Replace each selected image with a same-purpose `example.test/...:latest` reference and assert every matching Deployment container uses that reference and `imagePullPolicy: Always`. Include NHC's console Deployment and verify SNR/SBR agent environment strings separately.
- [ ] Add a direct helper test in new `internal/operands/pull_policy_test.go`, using `package operands` so the test can call the unexported helper. Use a synthetic pod spec with a configured latest container explicitly set to `IfNotPresent`, a configured latest init container, an unrelated container, and a digest container. Expect Always only on the matching configured latest containers; preserve other policies. This covers migration from an existing digest-defaulted Deployment without modifying embedded upstream fixtures.
- [ ] Run the focused tests and observe failure:

```sh
go test ./internal/operands -run 'Test.*Latest.*PullPolicy' -count=1
```

- [ ] Add a small renderer helper that visits `containers` and `initContainers` in a Deployment pod spec. Build an exact set of configured references ending in `:latest` from the component's image bindings and supplied image set. Set Always only when a container image is in that set. Call the helper after image replacement and YAML decoding and before appending the object. Propagate malformed unstructured data errors rather than panicking.
- [ ] Leave agent-pod policy to the upstream operand, which creates those pods. Do not add tag watching, restart annotations, deployment polling, or changes to upstream operators.
- [ ] Run all renderer, image-set, and component tests:

```sh
go test ./internal/operands ./internal/images ./internal/components -count=1
```

Expected: latest policies and references pass; existing digest substitutions, webhook failure policies, namespace rewrites, and agent image substitution tests remain green.

## Task 4: Documentation, generated outputs, and integration

- [ ] Update `AGENTS.md`'s first hard constraint to consume images exactly as recorded by `pullRef`: latest stays floating and other tags are pinned by digest. Preserve the prohibition on modifying, forking, or rebuilding components.
- [ ] Update README descriptions, release-set comments, manager comments, image-set and API status comments, generator comments, and any active runtime patch comments that claim every image is a pinned digest. Explain that the recorded commit is a manifest snapshot for latest. Explain `OPERAND_TAG=pinned` precisely. Leave archived historical designs unchanged.
- [ ] Run the offline generators and bundle regeneration:

```sh
make operand-manifests
make bundle-reset
```

- [ ] Review actual diffs. Every committed latest manager and bundle operand reference must be tag-only, with no `:latest@sha256:` combination. Release fixtures must still use repository digest references. Go tagged bindings remain based on `tagged`. CRD schema shape must remain unchanged; description updates are acceptable. No vendored source, webhook failure policy, default component state, or public spec field changes are allowed.
- [ ] Run focused tests and the pre-commit checks:

```sh
go test ./internal/components ./internal/images ./internal/operands -count=1
make test-offline
make check
git diff --check
```

- [ ] Commit the coherent migration with configured Git identity and the required Codex trailer. Include only intended source, tests, documentation, and generated files. Keep pull-policy code and its tests in a separate commit if the reference migration passes without them.
- [ ] On the resulting clean tree run the required push gates:

```sh
make test-offline
make test
git status --short
```

Expected: both targets succeed and the working tree remains clean. If generation changes files, inspect, include the justified generated updates, rerun `make check` before the corrective commit, then rerun clean-tree gates. Do not run a live `make bump-operands` or cluster deployment merely to validate the implementation.

## Completion criteria

- Default `make bump-operands` selects actual `:latest` pull references for every operand image.
- Releases and explicit non-latest tags remain digest pinned; mixed selections work.
- No legacy `pinned` image field is consumed or emitted.
- Generation, verification, manager environment values, bundle values, and rendered image substitutions agree.
- Latest Deployment containers explicitly check the registry at startup, including transitions from digest configurations.
- Source commits remain recorded and component defaults, webhook policies, and ownership behavior remain unchanged.
- Offline tests exercise both success and rejection cases; required checks pass before publishing changes.
