# MDR Memory Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set MDR manager memory defaults to a `64Mi` request and a `128Mi` limit through a WAO runtime overlay.

**Architecture:** A Kustomize patch changes only memory values in MDR's named manager container. Generated runtime manifests carry these defaults into the WAO binary. Existing WAC resource settings override the packaged values.

**Tech Stack:** Kustomize v5.8.1, Kubernetes Deployment manifests, Go, and the existing WAO manifest generation commands.

**Spec:** [Issue #40](https://github.com/jwmatthews/wao_poc/issues/40), including its follow-up comment, and the user's requested overlay change. Read [AGENTS.md](../../../AGENTS.md), [the overlay guide](../../operand-config-overlays.md), and [the generation guide](../../updating-operand-manifests.md).

## Global constraints

- This document authorizes no implementation. Start implementation only after the user requests it.
- Preserve CPU requests and limits at `100m`.
- Target Deployment `machine-deletion-remediation-controller-manager`, container `manager`.
- Keep the operand image selection unchanged. Do not modify or rebuild MDR.
- Never edit copied files under `config/operands/mdr/config/`.
- Never edit generated runtime manifests or bundle files directly.
- Keep all six component enable defaults at `false`.
- Preserve existing resource validation and WAC override behavior.
- Do not change probes, images, other operands, RBAC, or webhook policies.
- Use `gh` for GitHub reads. Obtain approval for each exact proposed GitHub write, including a push or pull request.
- Run `make check` before each implementation commit.
- Preserve the configured Git author and committer. Add the Codex trailer exactly once to each assisted commit.
- Run `make test-offline` and `make test` on a clean tree before any approved push.
- This change needs no live cluster test. Do not change the current cluster configuration during these tasks.

## Evidence and expected behavior

Issue #40 records a startup failure with a `30Mi` limit. Increasing that limit to `128Mi` restored startup in that attempt.
A later image build started successfully with the original defaults. The issue does not establish minimum or production memory requirements.
The `64Mi` request matches the setting selected by the user. It was not part of the issue's original limit-only experiment.

| Resource | Current packaged value | New packaged value |
| --- | --- | --- |
| CPU request | `100m` | `100m` |
| CPU limit | `100m` | `100m` |
| Memory request | `20Mi` | `64Mi` |
| Memory limit | `30Mi` | `128Mi` |

The overlay must survive a later refresh of the upstream copy.
After a WAO upgrade, an enabled MDR without resource overrides uses the new defaults.
An explicit, valid WAC override continues to apply. Removing an override restores the corresponding default from the installed WAO version.

A partial override can become invalid against the increased request.
For example, a memory limit of `32Mi` without an explicit request conflicts with the new `64Mi` request.
Existing validation must report the conflict and preserve the last valid Deployment.
An explicit `20Mi` request with a `30Mi` limit remains valid, although it retains the old values.

## File map

| File | Change |
| --- | --- |
| `config/operands/mdr/overlays/runtime/manager_resources_patch.yaml` | Create the memory-only patch. |
| `config/operands/mdr/overlays/runtime/kustomization.yaml` | Register the patch for MDR's named Deployment. |
| `internal/operands/manifests/mdr/objects.yaml` | Regenerate the embedded runtime objects. |
| `internal/operands/render_test.go` | Add a regression test for MDR defaults and overrides. |
| `docs/configuring-operand-resources.md` | Document MDR defaults and upgrade behavior. |

Run bundle generation as a consistency check. This runtime-only change should not change bundle content.
No existing MDR-specific test assertion uses the old `20Mi` or `30Mi` defaults.
Existing unit fixtures that use `20Mi` for a sidecar need no change.

## Task 1: Change and check the packaged defaults

**Interfaces:**

- Consumes: `components.MDR()`, `operands.Render`, and `operands.ApplyManagerResources`.
- Consumes: existing `testNamespace`, `testImages()`, and `find()` helpers in `internal/operands/render_test.go`.
- Produces: packaged MDR defaults of `64Mi` and `128Mi`, with the existing resource API unchanged.

- [ ] **Step 1: Add the regression test.**

Add this function to `internal/operands/render_test.go`. The file already imports all required packages.

```go
func TestRenderMDRManagerDefaults(t *testing.T) {
    for _, tc := range []struct {
        name string
        overrides *corev1.ResourceRequirements
        requestMemory, limitMemory string
    }{
        {name: "packaged defaults", requestMemory: "64Mi", limitMemory: "128Mi"},
        {name: "empty overrides", overrides: &corev1.ResourceRequirements{}, requestMemory: "64Mi", limitMemory: "128Mi"},
        {
            name: "partial memory override",
            overrides: &corev1.ResourceRequirements{
                Limits: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("256Mi")},
            },
            requestMemory: "64Mi", limitMemory: "256Mi",
        },
        {
            name: "explicit old values remain valid",
            overrides: &corev1.ResourceRequirements{
                Requests: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("20Mi")},
                Limits: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("30Mi")},
            },
            requestMemory: "20Mi", limitMemory: "30Mi",
        },
        {name: "fresh render restores defaults", requestMemory: "64Mi", limitMemory: "128Mi"},
    } {
        t.Run(tc.name, func(t *testing.T) {
            def := components.MDR()
            objects, err := operands.Render(def, testNamespace, testImages())
            if err != nil {
                t.Fatal(err)
            }
            if err := operands.ApplyManagerResources(def, objects, tc.overrides); err != nil {
                t.Fatal(err)
            }
            deployment := find(t, objects, "Deployment", def.ManagerDeployment)
            containers, found, err := unstructured.NestedSlice(deployment.Object, "spec", "template", "spec", "containers")
            if err != nil || !found {
                t.Fatalf("containers missing: %v", err)
            }
            for _, raw := range containers {
                container := raw.(map[string]any)
                if container["name"] != def.ManagerContainer {
                    continue
                }
                got, found, err := unstructured.NestedMap(container, "resources")
                if err != nil || !found {
                    t.Fatalf("manager resources missing: %v", err)
                }
                want := map[string]any{
                    "requests": map[string]any{"cpu": "100m", "memory": tc.requestMemory},
                    "limits": map[string]any{"cpu": "100m", "memory": tc.limitMemory},
                }
                if !reflect.DeepEqual(got, want) {
                    t.Fatalf("manager resources = %v, want %v", got, want)
                }
                return
            }
            t.Fatal("manager container missing")
        })
    }
}
```

- [ ] **Step 2: Check that the test fails against the old defaults.**

```sh
go test ./internal/operands -run '^TestRenderMDRManagerDefaults$' -count=1
```

Expected: default cases report `20Mi` and `30Mi` instead of `64Mi` and `128Mi`.
The case with explicit old values passes.

- [ ] **Step 3: Create the overlay patch.**

Create `config/operands/mdr/overlays/runtime/manager_resources_patch.yaml` with this content:

```yaml
# WAO memory defaults for MDR startup. See https://github.com/jwmatthews/wao_poc/issues/40.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: machine-deletion-remediation-controller-manager
spec:
  template:
    spec:
      containers:
        - name: manager
          resources:
            requests:
              memory: 64Mi
            limits:
              memory: 128Mi
```

Append this block to `config/operands/mdr/overlays/runtime/kustomization.yaml`:

```yaml
patches:
  - path: manager_resources_patch.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: machine-deletion-remediation-controller-manager
```

The strategic merge selects container `manager` by name. Omitted CPU fields retain their upstream values.

- [ ] **Step 4: Generate runtime objects and normalize the bundle.**

Run these commands separately from the repository root:

```sh
make operand-manifests
make bundle-reset
git diff -- internal/operands/manifests/mdr/objects.yaml
git diff -- config/operands/mdr/config config/manager/manager.yaml bundle
git diff -- internal/operands/manifests/nhc internal/operands/manifests/snr internal/operands/manifests/sbr internal/operands/manifests/far internal/operands/manifests/nmo
```

Expected: MDR's generated manager has two memory changes. Its CPU settings remain `100m`.
The other inspected paths have no changes. Investigate any additional change before continuing.
Do not refresh upstream configuration for this change.

- [ ] **Step 5: Check defaults, override precedence, and rendering isolation.**

```sh
go test ./internal/operands -count=1
```

Expected: all operand tests pass.
The new test checks the exact packaged defaults, partial overrides, explicit old values, and a fresh render after overrides.
Existing tests check every component's override handling, resource validation, and preservation of unrelated fields.

- [ ] **Step 6: Document the defaults.**

Insert the following section before `## Validation and status` in `docs/configuring-operand-resources.md`:

```markdown
## MDR packaged defaults

WAO supplies these defaults for the Machine Deletion Remediation (MDR) manager:

| Resource | Request | Limit |
| --- | --- | --- |
| CPU | `100m` | `100m` |
| Memory | `64Mi` | `128Mi` |

The WAO runtime overlay defines these values.
See [issue #40](https://github.com/jwmatthews/wao_poc/issues/40) for the startup observations.
The issue does not establish minimum or production memory requirements.

An enabled MDR uses these defaults when its WAC resource fields are omitted.
Valid explicit overrides continue to apply after an upgrade.
Removing an override restores that entry's default from the installed WAO version.

A memory limit below `64Mi` requires an explicit request that does not exceed the limit.
Otherwise, validation reports a conflict and preserves the last valid Deployment.

WAO embeds these defaults in its binary.
Changing the overlay requires runtime manifest generation and a new WAO image.
Deploy that image through an updated WAO bundle to change an installed operator.
MDR needs no image rebuild.
```

- [ ] **Step 7: Check the complete change before committing.**

```sh
gofmt -w internal/operands/render_test.go
make check
make test-offline
git diff --check
git status --short
git diff
```

Expected: all checks pass. Only the five implementation files in the file map change.
The plan file can also appear if it has not yet been committed.
Confirm that no sample or CRD introduces numeric resource defaults.

- [ ] **Step 8: Commit the reviewed local change.**

Include this plan if it is still untracked. Stage only these files:

```sh
git add docs/superpowers/plans/2026-10-31-mdr-memory-defaults.md config/operands/mdr/overlays/runtime/manager_resources_patch.yaml config/operands/mdr/overlays/runtime/kustomization.yaml internal/operands/manifests/mdr/objects.yaml internal/operands/render_test.go docs/configuring-operand-resources.md
git commit -m "fix: raise MDR packaged memory defaults" -m "Set the MDR manager memory request to 64Mi and limit to 128Mi through the WAO runtime overlay. Preserve CPU settings and WAC overrides. References #40." -m "Co-authored-by: Codex <noreply@openai.com>"
```

Do not include unrelated files. Do not change the configured Git identity.

- [ ] **Step 9: Check the committed tree.**

```sh
git status --porcelain
make test-offline
make test
git status --porcelain
```

Expected: both status commands produce no output. Both test commands pass.
`make test` uses envtest and checks generated files. It does not need the live cluster.
If generation changes tracked files, inspect those changes before another commit.
Repeat the required checks after a correction.

## Delivery and acceptance

The change is complete when the overlay and generated runtime manifest contain the new memory defaults.
The tests must pass with CPU values unchanged and valid WAC overrides preserved.
The documentation must explain defaults, partial conflicts, and upgrade behavior.

An installed WAO will continue to use its embedded manifests until it receives the new WAO image.
Building, publishing, and deploying that image are later release steps. This plan does not authorize those actions.
Do not remove the user's current MDR override during implementation.
No GitHub comment, issue update, push, or pull request is part of this plan's execution without specific approval.
