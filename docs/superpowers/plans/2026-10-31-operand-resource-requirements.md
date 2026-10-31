# Operand Resource Requirements Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task after the user requests implementation. Use the checkboxes to track progress.

**Goal:** Let administrators enable components and configure manager resources through boolean fields and OpenShift console controls.

**Architecture:** Replace each component's string `state` field with boolean `enabled`, defaulting to false. Add optional `manager.resources` settings and CSV descriptors for both controls. Merge resource overrides with packaged defaults before applying component objects.

**Tech Stack:** Go 1.24 module, Kubernetes libraries v0.33.0, controller-runtime v0.21.0, controller-gen v0.20.1, Operator SDK v1.42.2, Ginkgo, and envtest.

**Spec:** [Issue #38](https://github.com/jwmatthews/wao_poc/issues/38), [issue #43](https://github.com/jwmatthews/wao_poc/issues/43), and the user's explicit boolean API requirement. Console CR creation is part of the required behavior.

**Status:** Implementation and console checks are complete. Task 6 records the verification commands.

**Repository baseline:** `e7ea1854365400607a42e18beac35c75d59daf22`, inspected on 2026-10-31.

## Global constraints

- Consume the selected operand images without modifying, forking, or rebuilding their operators.
- Every component defaults to `enabled: false` and remains disabled after installation.
- Installing WAO must not create a remediation policy, remediation request, native config, or node agent.
- Never change a component webhook `failurePolicy`.
- Never adopt an existing object that WAO did not create.
- Do not add a public API field that overrides a component image.
- Never edit `config/operands/<key>/config/` directly.
- Never edit generated runtime objects or generated bundle files directly.
- Replace `spec.components.<key>.state` with `spec.components.<key>.enabled` for all six components.
- Use boolean values, not strings. Omitted `enabled` fields mean false.
- Generate CSV boolean switches and resource controls for the console creation form.
- Keep the declared minimum Kubernetes version at `1.25.0` for this change.
- Keep implementation plans in `docs/superpowers/plans/`.
- Use `gh` for GitHub access. Obtain specific approval before any GitHub write.
- Run `make check` before each implementation commit.
- Preserve the configured Git identity. Append `Co-authored-by: Codex <noreply@openai.com>` once to each assisted commit.
- Run live tests only on a disposable OpenShift cluster that the user identifies and authorizes in the current session.
- Pass the kubeconfig explicitly for each cluster command.

## Proposed design

### API and scope

Use this API shape:

```yaml
apiVersion: workloadavailability.medik8s.io/v1alpha1
kind: WorkloadAvailabilityConfig
metadata:
  name: cluster
spec:
  components:
    nodeHealthCheck:
      enabled: true
      manager:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

Use the existing API group, `WorkloadAvailabilityConfig` kind, and singleton name `cluster`. Replace the current string field with `enabled: true` or `enabled: false`.

Use `Enabled bool` with a CRD default of false. A missing component or missing `enabled` field must never enable an operand. Do not retain `state` as a second supported input.

Keep `ComponentState` and `StateOf` only for the existing controller and status representation. Derive their values from `Enabled`. Status may continue to report `desiredState: Enabled|Disabled` and lifecycle phases.

Recommend `manager.resources` because issue #43 proposes that path. It identifies which workload receives the settings. Place these settings beside the enable control within each component's console section.

Support `cpu` and `memory` in `requests` and `limits`. Use `*corev1.ResourceRequirements` for the field. Report unsupported resource names and nonempty `claims` clearly. This issue does not introduce device claims or extended resources.

Keep these workloads and settings outside this change:

- The WAO manager itself, which has separate OLM Subscription configuration.
- The NHC console plugin Deployment.
- Operand sidecars and init containers.
- Agent DaemonSets and other workloads created by operands.
- Operand-native configuration resources.
- Scheduling fields such as `nodeSelector`, tolerations, and `priorityClassName`.

### Existing configurations

Replacing `state` is a breaking change to the current `v1alpha1` spec. Update active samples, scripts, bootstrap fixtures, and controller tests in the same change.

Document this conversion for saved configurations:

| Previous input | New input |
| --- | --- |
| `state: Enabled` | `enabled: true` |
| `state: Disabled` | `enabled: false` |
| Component state omitted | `enabled: false`, or omit the field |

Remove each old `state` field after conversion. Preserve resource settings and all unrelated fields. Historical plans and archived documents can retain their original examples.

Do not describe an existing installation as compatible without migration. A new controller could interpret an old `state: Enabled` configuration as disabled. A controlled upgrade must preserve the old configuration before changing the CRD. Install the converted configuration before the new controller starts reconciliation.

Do not patch `enabled` into the old CRD and assume it persists. Kubernetes can prune fields absent from that schema. Use fresh disposable installations for this plan's console tests. Document the migration requirement rather than promising an unattended upgrade.

### Defaults and merge rules

The embedded runtime manifest is the only source of defaults. Do not copy its numeric values into Go, CRD defaults, CSV examples, or merge logic.

| Configuration | Result |
| --- | --- |
| `manager` or `resources` omitted | Preserve the packaged manager resources |
| `resources: {}` or an empty resource map | Preserve the packaged manager resources |
| One CPU or memory value supplied | Replace only that map entry |
| A value omitted | Keep the corresponding packaged value, if present |
| A previously supplied value removed | Restore the packaged value, or remove the WAO-owned field when no packaged value exists |
| A value explicitly set to zero | Treat zero as a supplied quantity, subject to validation |
| Resources configured with `enabled: false` | Store the settings without creating workloads |

A partial override can conflict with a default. For example, SBR requests `64Mi` by default. A memory limit of `32Mi` alone must fail validation. The administrator must also reduce the request.

Removing an override does not remove a packaged limit. This API does not provide a separate operation to clear packaged defaults. An operand refresh can change an omitted value because the packaged default changes.

The current manager defaults are reference data for tests and review:

| Component | CPU request | Memory request | CPU limit | Memory limit |
| --- | --- | --- | --- | --- |
| NHC | `100m` | `20Mi` | Absent | Absent |
| SNR | `20m` | `110Mi` | Absent | Absent |
| SBR | `10m` | `64Mi` | `500m` | `128Mi` |
| FAR | `10m` | `64Mi` | `500m` | `512Mi` |
| MDR | `100m` | `20Mi` | `100m` | `30Mi` |
| NMO | `100m` | `20Mi` | `200m` | `100Mi` |

### Validation and failure behavior

Use the generated CRD quantity schema for structural checks. Add envtest cases that submit malformed quantities through an unstructured client. A typed client cannot submit malformed `resource.Quantity` values.

The implementation adds `hack/manager-resource-schema.sh` to `make manifests` after controller-gen.
The generated standard quantity pattern accepts fractional exponents and exponents outside the signed int64 range.
The helper restricts these exponents in all six components, for both requests and limits.
It preserves the standard `ResourceRequirements` type and the Kubernetes 1.25 minimum.
Offline tests check both generated CRDs.
Admission tests use an unstructured target and server dry-run.
This prevents response decoding errors from concealing server acceptance of malformed quantities.

Perform semantic checks in Go after the merge. Check negative quantities, unsupported resource names, unsupported claims, and requests that exceed effective limits. Compare quantities with `resource.Quantity.Cmp`. Do not compare strings or convert quantities to floating point.

This choice uses the status option allowed by issue #38. A new admission webhook would add installation and certificate requirements. Quantity-aware CEL functions require Kubernetes 1.28, which exceeds the CSV's declared minimum of 1.25.

For an invalid enabled component:

1. Return the validation error before applying any of its objects.
2. Keep its existing Deployment configuration.
3. Set its phase to `Degraded` through the existing controller error path.
4. Include the full configuration path and the conflicting effective values in its message.
5. Continue reconciling the other components.
6. Recover after the administrator corrects the configuration.

Example message:

```text
spec.components.storageBasedRemediation.manager.resources.requests.memory: effective request 64Mi exceeds effective limit 32Mi
```

Keep disable and finalization independent of resource validation. A user must be able to disable or delete a configuration with invalid overrides. Semantic checks run when a component is enabled. Document this timing.

Cluster admission policies still apply. A LimitRange or ResourceQuota can reject a Deployment or its Pods. Do not claim that local validation proves cluster capacity or policy compliance. Preserve API errors in status. The existing controller can remain `Progressing` when Deployment creation succeeds but Pod creation fails.

### Manager selection and reconciliation

Add explicit manager Deployment and container names to `components.Definition`. All six manager containers are currently named `manager`.

| Definition | Manager Deployment |
| --- | --- |
| `NHC()` | `node-healthcheck-controller-manager` |
| `SNR()` | `self-node-remediation-controller-manager` |
| `SBR()` | `sbr-operator-controller-manager` |
| `FAR()` | `fence-agents-remediation-controller-manager` |
| `MDR()` | `machine-deletion-remediation-controller-manager` |
| `NMO()` | `node-maintenance-operator-controller-manager` |

Do not select a container by array position. Do not apply the override to every Deployment. NHC has a second Deployment for its console plugin.

Keep `operands.Render` unchanged. Add a separate resource transformation after rendering in `ensureEnabled`. Transform only the selected container's `resources` subtree. Avoid a full typed Deployment conversion that could remove unrelated fields.

Reuse server-side apply, the existing ownership check, and the Deployment watch. A Pod template change starts a normal Deployment rollout. No explicit deletion, restart annotation, or new watcher is required.

### OpenShift console

Add these CSV `specDescriptors` for each of the six components:

```yaml
- displayName: Node Health Check Enabled
  description: Run the Node Health Check operator. The default is false.
  path: components.nodeHealthCheck.enabled
  x-descriptors:
    - urn:alm:descriptor:com.tectonic.ui:booleanSwitch
- displayName: Node Health Check Manager Resources
  description: Set CPU and memory for the manager container only.
  path: components.nodeHealthCheck.manager.resources
  x-descriptors:
    - urn:alm:descriptor:com.tectonic.ui:resourceRequirements
```

Replace the old State selectors with boolean switches. Remove their `.state` descriptor paths and `select:Enabled` / `select:Disabled` values. Preserve each component's explanatory text, including the effects of enabling SNR.

Use nested schema objects to group controls in the creation form.
The CSV details renderer groups only the first object level.
Run `hack/manager-resource-descriptors.sh` after Operator SDK generates the base CSV.
Derive component names from the parent descriptors.
Add each component name to its enable, manager, and resource labels.
Sort descriptor paths to keep each component's controls together.
Offline tests check these labels and their positions in both CSVs.
Do not use the deprecated `fieldGroup` descriptor.
Do not hide these controls under advanced settings.

Update the CSV's `metadata.annotations.alm-examples` to use `enabled: false` for all six components. Keep the name `cluster` and omit resource overrides from this default example. Put the form controls under `spec.customresourcedefinitions.owned[].specDescriptors`. These descriptors and the example annotation serve different purposes.

Support creation through the console form and editing through the CSV details controls.
A user must be able to enable a component and enter resources without editing YAML.
The creation form must show all components disabled initially.
Cluster-scoped resource links can open the generic details page, where Edit opens YAML.
Document the CSV details address, the switch confirmation, and the resource dialogs.
Leave the standard control's Storage fields empty because WAO supports CPU and memory only.

WAO already creates the singleton automatically. Document that users normally edit this existing object. Manual creation uses the same form and the required name `cluster` when the singleton is absent. Do not remove automatic creation or permit additional singleton names.

Generate descriptors from API markers through the existing bundle workflow. Check the generated base CSV and bundle CSV. The `order` marker alone does not prove the final form layout.

The OpenShift Console `release-4.20` reference documents boolean switches, resource controls, and automatic schema grouping. No target cluster version was supplied. Check both creation and CSV details editing on the authorized target version before declaring the console requirement complete.

## Task 1: Replace the state input and add resource fields

**Files:**

- Modify `api/v1alpha1/workloadavailabilityconfig_types.go`.
- Modify `api/v1alpha1/workloadavailabilityconfig_types_test.go`.
- Modify `internal/controller/bootstrap_test.go`.
- Modify `internal/controller/workloadavailabilityconfig_controller_test.go` to convert existing input fixtures.
- Check `internal/controller/bootstrap.go` for the same false-default behavior.
- Regenerate `api/v1alpha1/zz_generated.deepcopy.go`.
- Regenerate `config/crd/bases/workloadavailability.medik8s.io_workloadavailabilityconfigs.yaml`.

**Interfaces:**

- Replace `ComponentSpec.State` with `ComponentSpec.Enabled bool` using `json:"enabled"`.
- Keep explicit false values in serialized component objects. Mark the field optional with a CRD default of false.
- Add `ComponentSpec.Manager *ManagerSpec`.
- Add `ManagerSpec.Resources *corev1.ResourceRequirements`.
- Add `ManagerResourcesOf(key string) *corev1.ResourceRequirements` on `WorkloadAvailabilityConfigSpec`.
- Return a deep copy from `ManagerResourcesOf`. Return nil for an unknown key or omitted resources.
- Extract the existing key switch into private `componentOf(key string) (ComponentSpec, bool)`.
- Use `componentOf` in both `StateOf` and `ManagerResourcesOf`.
- Make `StateOf` return `ComponentStateEnabled` only when the selected component has `Enabled == true`.

- [x] Replace the existing API tests with boolean input cases for all six component keys.
- [x] Check true, false, omitted values, and unknown keys through `StateOf`.
- [x] Check that JSON serialization preserves boolean false without producing a `state` field.
- [x] Add accessor tests for all six component keys, omitted fields, an unknown key, and independent deep copies.
- [x] Add a JSON round-trip test that preserves explicit zero and empty resource maps.
- [x] Run `go test ./api/v1alpha1 -count=1` before adding the API fields.

An initial accessor test can use this form:

```go
func TestManagerResourcesOfUnknownKey(t *testing.T) {
    spec := WorkloadAvailabilityConfigSpec{}
    if got := spec.ManagerResourcesOf("unknown"); got != nil {
        t.Fatalf("unknown component returned resources: %v", got)
    }
}
```

- [x] Replace the input field and add the manager field with these markers.

```go
type ComponentSpec struct {
    // Enabled runs the operator when true. The default is false.
    // Disabling removes its manager and managed installation resources.
    // Existing agents, configuration, and native resources can remain.
    // Complete active maintenance or remediation before disabling.
    // +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Enabled",xDescriptors={"urn:alm:descriptor:com.tectonic.ui:booleanSwitch"}
    // +kubebuilder:default=false
    // +optional
    Enabled bool `json:"enabled"`

    // Manager configures the operand manager container.
    // +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Manager"
    // +optional
    Manager *ManagerSpec `json:"manager,omitempty"`
}

// ManagerSpec configures the operand manager container.
type ManagerSpec struct {
    // Resources overrides CPU and memory requests and limits.
    // Omitted values use the packaged manager defaults.
    // These settings do not configure agents or the console plugin.
    // +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Manager Resources",xDescriptors={"urn:alm:descriptor:com.tectonic.ui:resourceRequirements"}
    // +optional
    Resources *corev1.ResourceRequirements `json:"resources,omitempty"`
}
```

- [x] Derive `StateOf` from `Enabled` and retain its existing status return type.
- [x] Update the `ComponentState` comment to describe its controller and status purpose.
- [x] Implement the accessor with `c.Manager.Resources.DeepCopy()` after the nil checks.
- [x] Replace the controller test helper with `setEnabled(ctx context.Context, key string, enabled bool)`.
- [x] Convert all test assignments from `.State` to `.Enabled` with boolean values.
- [x] Check that bootstrap leaves an existing enabled configuration unchanged.
- [x] Run `make generate manifests`.
- [x] Run `go test ./api/v1alpha1 -count=1` again.
- [x] Run `go test ./internal/controller -run '^TestEnsureDefaultConfig' -count=1`.
- [x] Check that each generated component schema contains optional `manager.resources` without numeric defaults.
- [x] Check each component schema for `enabled` with `type: boolean` and `default: false`.
- [x] Check that no component spec schema retains the old `state` property.

**Expected result:** API and bootstrap tests pass. Omitted settings remain disabled. The new spec uses boolean inputs, while existing status values remain available.

## Task 2: Identify each manager explicitly

**Files:**

- Modify `internal/components/component.go`.
- Modify `internal/components/nhc.go`, `snr.go`, `sbr.go`, `far.go`, `mdr.go`, and `nmo.go`.
- Modify `internal/components/components_test.go`.

**Interfaces:** Add `ManagerDeployment string` and `ManagerContainer string` to `Definition`.

- [x] Extend registry tests to parse the rendered Deployments for every component.
- [x] Require one declared manager Deployment and one matching manager container.
- [x] Require the manager Deployment to remain in `Definition.Deployments`.
- [x] Run `go test ./internal/components -count=1` before adding the fields.
- [x] Populate the names from the manager table above.

For NHC, the new fields are:

```go
ManagerDeployment: "node-healthcheck-controller-manager",
ManagerContainer:  "manager",
```

- [x] Retain both existing NHC entries in `Deployments` for readiness and removal.
- [x] Run `go test ./internal/components -count=1` again.

**Expected result:** A future operand rename fails a registry test instead of silently applying resources to the wrong workload.

## Task 3: Merge and check manager resources

**Files:**

- Create `internal/operands/resources.go`.
- Create `internal/operands/resources_test.go`.
- Extend `internal/operands/render_test.go` with cross-component checks.

**Interfaces:**

```go
func ApplyManagerResources(
    def components.Definition,
    objects []*unstructured.Unstructured,
    overrides *corev1.ResourceRequirements,
) error

func mergeResources(
    defaults corev1.ResourceRequirements,
    overrides corev1.ResourceRequirements,
) (corev1.ResourceRequirements, error)
```

`ApplyManagerResources` is public. `mergeResources` is private. The private helper validates the override and the merged result. The public helper adds the component configuration path to errors.

- [x] Add the following unit test before implementing the merge helper.

```go
func TestMergeResourcesRejectsLimitBelowDefaultRequest(t *testing.T) {
    defaults := corev1.ResourceRequirements{
        Requests: corev1.ResourceList{
            corev1.ResourceMemory: resource.MustParse("64Mi"),
        },
    }
    overrides := corev1.ResourceRequirements{
        Limits: corev1.ResourceList{
            corev1.ResourceMemory: resource.MustParse("32Mi"),
        },
    }
    _, err := mergeResources(defaults, overrides)
    if err == nil {
        t.Fatal("accepted a limit below the effective request")
    }
}
```

- [x] Add table cases for the behaviors below.

| Case | Required assertion |
| --- | --- |
| Nil override | Every rendered object remains unchanged |
| Empty override | Defaults remain unchanged |
| Only CPU request | Memory values and limits remain unchanged |
| Only memory limit | CPU values and memory request remain unchanged |
| Full override | All four supplied values appear on the manager |
| Equal request and limit | Accept the pair, including equivalent quantity units |
| Request above inherited limit | Return a path-specific error |
| Limit below inherited request | Return a path-specific error |
| Negative quantity | Return an error for the offending field |
| Zero request with a valid limit | Preserve the zero request |
| Unsupported resource or nonempty claims | Return an error instead of silently ignoring it |
| Missing or duplicate manager target | Return an error when an override is supplied |
| Sidecar before manager | Change the named manager only |
| Sidecar, init container, NHC plugin | Preserve each unrelated resources subtree |
| Repeated renders with different overrides | Do not retain values from the previous render |
| Merge input reuse | Do not modify default or override maps |

- [x] Run `go test ./internal/operands -count=1` and check the expected failures.
- [x] Implement map-entry replacement on a deep copy of the packaged resources.

Use this operation for each accepted request or limit entry:

```go
effective := defaults.DeepCopy()
if len(overrides.Requests) > 0 && effective.Requests == nil {
    effective.Requests = corev1.ResourceList{}
}
for name, quantity := range overrides.Requests {
    effective.Requests[name] = quantity.DeepCopy()
}
if len(overrides.Limits) > 0 && effective.Limits == nil {
    effective.Limits = corev1.ResourceList{}
}
for name, quantity := range overrides.Limits {
    effective.Limits[name] = quantity.DeepCopy()
}
```

- [x] Reject nonempty claims and keys other than `corev1.ResourceCPU` and `corev1.ResourceMemory` in the override.
- [x] Check CPU and memory in a fixed order so error messages remain stable.
- [x] Reject negative quantities with `quantity.Sign() < 0`.
- [x] Compare each effective request with its effective limit when both entries exist.

```go
request, hasRequest := effective.Requests[name]
limit, hasLimit := effective.Limits[name]
if hasRequest && hasLimit && request.Cmp(limit) > 0 {
    return corev1.ResourceRequirements{}, fmt.Errorf(
        "requests.%s: effective request %s exceeds effective limit %s",
        name, request.String(), limit.String(),
    )
}
```

- [x] Implement `ApplyManagerResources` with an immediate return for a nil override.
- [x] Locate the explicit Deployment and container before modifying any object.
- [x] Read the resources subtree with `unstructured.NestedMap`.
- [x] Convert only that subtree with `runtime.DefaultUnstructuredConverter`.
- [x] Merge and validate before replacing the subtree.
- [x] Return conversion or selection errors with the component and target names.
- [x] Run `go test ./internal/operands ./internal/components -count=1` again.

**Expected result:** Overrides affect only the selected manager. Invalid input leaves the rendered objects unchanged.

## Task 4: Integrate reconciliation and check lifecycle behavior

**Files:**

- Modify `internal/controller/workloadavailabilityconfig_controller.go`.
- Modify `internal/controller/workloadavailabilityconfig_controller_test.go`.
- Extend `internal/controller/status_test.go` only if the existing status checks need additional coverage.

**Consumes:** `ManagerResourcesOf` from Task 1 and `ApplyManagerResources` from Task 3.

- [x] Add envtest cases for schema acceptance and malformed quantity rejection.
- [x] Check that omitted `enabled` defaults to false and explicit true enables the selected component.
- [x] Reject string values such as `enabled: "true"`, `enabled: "false"`, and `enabled: Enabled` at admission.
- [x] Check that a strict field-validation request rejects the removed `state` input.
- [x] Add enabled-component cases for application, drift repair, changes, removal, and invalid merged values.
- [x] Use SBR for an inherited-default conflict and NHC for removal of a limit absent from defaults.
- [x] Add checks that invalid configuration in one component does not prevent another component from reconciling.
- [x] Add checks for disable and deletion with invalid overrides.
- [x] Run the controller tests before adding the integration call.

Use the repository's test environment:

```sh
make envtest
KUBEBUILDER_ASSETS="$(bin/setup-envtest use 1.34 -p path --bin-dir "$PWD/testbin")" \
  go test ./internal/controller -count=1
```

Insert this call after successful rendering in `ensureEnabled`, before the apply loop:

```go
if err := operands.ApplyManagerResources(
    def, objs, wac.Spec.ManagerResourcesOf(def.Key),
); err != nil {
    return st, err
}
```

- [x] Retain the existing foreign-object guard, field owner, and apply options.
- [x] Leave `ensureDisabled` and finalization free of override validation.
- [x] Run the controller tests again.

Use the existing ordered suite's setup and cleanup. Each case must restore the enable flags and resource settings it changes.

Required controller assertions:

1. CRs using the new boolean API preserve packaged resources when overrides are absent.
2. Overrides work for all six managers.
3. Resource settings alone do not enable a component.
4. A valid update changes the target Pod template.
5. Reconciliation repairs a manual edit to a configured resource value.
6. Removing an override restores the packaged default.
7. Removing an NHC limit removes the field previously owned by WAO.
8. A resource update does not change another component's Pod template or the NHC plugin template.
9. Repeated reconciliation with the same settings does not increment the target Deployment generation.
10. Invalid enabled settings produce `Degraded` status and an actionable message.
11. Invalid settings leave the last valid target Deployment intact.
12. Corrected settings clear the error and resume normal reconciliation.
13. Invalid settings do not prevent disable or finalization.
14. A foreign Deployment remains unchanged when resources are configured.
15. Switching `enabled` from true to false removes the selected manager through the existing disable sequence.
16. Bootstrap creates no operand workloads and preserves an existing configuration's boolean values.

Envtest does not run the Deployment controller or kubelet. Check desired templates, generations, status messages, and ownership there. Check actual Pod rollouts on OpenShift in Task 6.

Server-side apply removal needs an API-server test. If a field persists, inspect managed fields before changing ownership logic. Do not replace the whole resources map to solve removal.

## Task 5: Generate console controls and document the API

**Files:**

- Finalize markers and comments in `api/v1alpha1/workloadavailabilityconfig_types.go`.
- Regenerate `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml` through Operator SDK.
- Regenerate the WAO CRD and CSV under `bundle/manifests/`.
- Create `test/offline/resource_configuration_test.go`.
- Modify `README.md`.
- Modify `hack/enable_all.sh` to send boolean `enabled: true` values for all six components.
- Modify `config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml` to use `enabled: false`.
- Create `docs/configuring-operand-resources.md`.
- Create `config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig_resources.yaml`.

- [x] Add an offline test that parses the generated base and bundle CSVs.
- [x] Require one resource descriptor at `components.<key>.manager.resources` for every component key.
- [x] Require the `resourceRequirements` descriptor value at each path.
- [x] Require one `booleanSwitch` descriptor at `components.<key>.enabled` for every component.
- [x] Require boolean CRD fields with false defaults for all six components.
- [x] Reject old `.state` descriptor paths and the old string-selection descriptors.
- [x] Reject duplicate descriptor paths and descriptors that do not match the CRD schema.
- [x] Check both generated CRD copies for the six optional resource fields.
- [x] Parse the default sample and `alm-examples` to check six explicit boolean false values without resource overrides.
- [x] Check that both examples use `WorkloadAvailabilityConfig`, the existing API group, and the singleton name `cluster`.
- [x] Check that the enable script sends boolean true values and no old `state` inputs.
- [x] Run `go test ./test/offline -run ResourceConfiguration -count=1` before regeneration.
- [x] Update the default sample to use six explicit `enabled: false` values.
- [x] Update `alm-examples` in the base CSV source to use six boolean false values.
- [x] Update the enable script to use six boolean true values.
- [x] Run `make generate manifests`.
- [x] Run `make bundle-reset` to generate normalized CSV and bundle output.
- [x] Check descriptor names, paths, and ordering in the generated files.
- [x] Run `go test ./test/offline -run ResourceConfiguration -count=1` again.

Implement the CSV checks with `sigs.k8s.io/yaml` and `unstructured.NestedSlice`. Index descriptors by their `path`. Compare the six required paths with `v1alpha1.AllComponentKeys`.

Do not hand-edit generated descriptors to make the test pass. If Operator SDK does not emit the marker correctly, correct the source marker or generation step. Keep that correction covered by the offline test.

- [x] Write the user guide with the API example above.
- [x] Explain console creation and editing with enable switches and resource controls.
- [x] Explain that the existing singleton must be edited when WAO has already created it.
- [x] Document the breaking API change and conversion of old configurations.
- [x] Document partial overrides, inherited defaults, removal, validation timing, and status errors.
- [x] Explain that manager settings do not configure agents or the console plugin.
- [x] Explain that resource changes use the Deployment's existing rollout strategy.
- [x] Explain how to inspect the effective Deployment resources and component status.
- [x] Add a README link to the guide.
- [x] Update active README examples to use boolean inputs.
- [x] Create the separate resources sample with `nodeHealthCheck.enabled: false` and the example resource values.
- [x] Keep that sample outside `config/samples/kustomization.yaml` so the default sample remains minimal.

**Expected result:** Generated artifacts expose six boolean switches and six resource controls. Samples, scripts, and documentation use the new API consistently.

## Task 6: Run final checks and inspect the OpenShift form

### Local checks

- [x] Run the API, component, and operand unit tests explicitly.

```sh
go test ./api/v1alpha1 ./internal/components ./internal/operands -count=1
```

`make test` currently runs the controller package. It does not replace the command above.

- [x] Run `make bundle-reset` after all source changes.
- [x] Run `make check` before each implementation commit.
- [x] Make small local commits after the corresponding tests pass.
- [x] Preserve the configured Git identity and required Codex trailer.
- [x] Run `make test-offline` on the clean implementation tree.
- [x] Run `make test` on that tree.
- [x] Run `git diff --check`.

The current working tree contains unrelated untracked files. Preserve them. Execute implementation in an isolated worktree so `verify-no-changes` can check a clean tree. Do not remove the user's files to satisfy that check.

### OpenShift checks

The following checks need a disposable cluster with classic OLM and explicit session authorization. Use the shared `dev/dev.mk` workflow. Do not recreate the removed cluster scripts.

- [x] Identify the authorized cluster and its OpenShift Console version.
- [x] Deploy with an explicit kubeconfig through `make dev-olm-deploy`.
- [x] Check that all six components have `enabled: false` after installation.
- [x] Use this fresh installation, with no operands enabled, for the creation test.
- [x] Remove only the empty singleton and wait for its deletion to complete.
- [x] Open the console's Create form without restarting WAO.
- [x] Check that the example supplies the singleton name `cluster` and six false enable flags.
- [x] Check that all six switches and resource controls appear in their component sections.
- [x] Recreate the singleton through the form with every component disabled.
- [x] Check that creation succeeds without YAML editing or operand workload creation.
- [x] Open the existing `WorkloadAvailabilityConfig/cluster` on the CSV details page.
- [x] Check all six component sections for the Enabled switch and resource controls.
- [x] Check that saved enable values are booleans and that the CR contains no component `state` input.
- [x] Check CPU units, memory units, partial values, save behavior, and removal of an override.
- [x] Check that console editing does not insert resource defaults into untouched components.
- [x] Enable NHC with a valid resource override.
- [x] Change one NHC resource value through a CSV details dialog.
- [x] Check the resulting Deployment rollout and effective manager resources.
- [x] Check that the console plugin and other component templates remain unchanged.
- [x] Submit an invalid effective request/limit pair on NHC and check the status message.
- [x] Correct the pair and check recovery.
- [x] Remove the override and check restoration of packaged defaults.
- [x] Set NHC's switch to false and check the normal manager removal behavior.

NHC provides a rollout check without requiring a real health policy. Do not create a `NodeHealthCheck` policy, remediation request, `StorageBasedRemediationConfig`, or `NodeMaintenance` for these tests. Do not enable SNR merely to inspect its controls because enabling it starts agents.

Use server-side dry-run for admission-only checks. Never capture Secret values or cluster-identifying details in repository documents. Review any sanitized test report before committing it.

If the target console version cannot edit nested resources through the CSV details controls, the console requirement remains incomplete.

## Acceptance coverage

| Requirement | Tasks and evidence |
| --- | --- |
| Boolean enable input for every component | Task 1 API and bootstrap tests, Task 4 admission and lifecycle tests |
| False defaults and rejection of string inputs | Tasks 1, 4, and 5 schema and sample checks |
| Updated samples, scripts, and migration guidance | Tasks 1 and 5 |
| Optional resources for each component | Task 1 API tests and Task 5 CRD checks |
| Apply and reconcile manager resources | Tasks 3 and 4, including all-six coverage and drift repair |
| Preserve omitted defaults | Tasks 3 and 4, including absent NHC/SNR limits |
| Support partial specifications | Task 3 merge cases and Task 4 API-server checks |
| Reject or report invalid values | Task 4 admission checks and Degraded status checks |
| Roll out one component independently | Task 4 template checks and Task 6 live rollout |
| Restore defaults after override removal | Task 4 server-side apply checks and Task 6 live check |
| Provide documentation and examples | Task 5 guide, README link, and boolean false samples |
| Create the CR through the console form | Task 5 descriptors and example annotation, Task 6 creation test |
| Provide resources beside each enable switch | Task 5 descriptor tests and Task 6 creation and editing checks |

## Source references

- [Issue #38](https://github.com/jwmatthews/wao_poc/issues/38).
- [Console requirement in issue #38](https://github.com/jwmatthews/wao_poc/issues/38#issuecomment-6421699404).
- [Manager resources proposal in issue #43](https://github.com/jwmatthews/wao_poc/issues/43#issuecomment-6529892013).
- [OpenShift Console 4.20 descriptor reference](https://github.com/openshift/console/blob/release-4.20/frontend/packages/operator-lifecycle-manager/src/components/descriptors/reference/reference.md).
- [Kubernetes v0.33.0 resource types](https://github.com/kubernetes/api/blob/v0.33.0/core/v1/types.go).
- [Quantity CEL library version registration](https://github.com/kubernetes/apiserver/blob/v0.33.0/pkg/cel/environment/base.go).
- [Project overlay guide](../../operand-config-overlays.md).
- [Project manifest update guide](../../updating-operand-manifests.md).

The console inspection required two changes to the original approach.
The CSV details page needs component names in its flattened labels.
Cluster-scoped resource links can open the generic YAML editor instead of that page.
The user guide provides a command for the CSV details address.
The generation helper and offline tests preserve the corrected labels.
