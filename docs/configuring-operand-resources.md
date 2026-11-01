# Configure operand manager resources

WAO uses `WorkloadAvailabilityConfig/cluster` to configure its six component operators.
Each component has a boolean `enabled` field.
The default is `false`.
An omitted component or enable field remains disabled.
Use `true` and `false` without quotes.

Set `spec.components.<key>.manager.resources` to configure the selected manager container.
The field has `requests` and `limits` objects, each with optional `cpu` and `memory` fields.
WAO supports CPU and memory only.
Each value is a Kubernetes quantity written as a string, such as `"500m"`, or an integer, such as `1`.
Resource settings alone do not enable a component.

This example enables Node Health Check (NHC) and configures its manager:

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

The [resource sample](../config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig_resources.yaml)
uses these settings with `enabled: false`.
The [default sample](../config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml)
sets all six enable fields to false and omits resources.
The resource sample is outside the sample Kustomization.

The six component keys are:

| Component | Key |
| --- | --- |
| Node Health Check | `nodeHealthCheck` |
| Self Node Remediation | `selfNodeRemediation` |
| Storage Based Remediation | `storageBasedRemediation` |
| Fence Agents Remediation | `fenceAgentsRemediation` |
| Machine Deletion Remediation | `machineDeletionRemediation` |
| Node Maintenance | `nodeMaintenance` |

## Partial settings and packaged defaults

WAO reads manager defaults from its packaged operand manifests.
The API and console example do not define separate numeric defaults.
WAO replaces only the supplied CPU or memory entries.
Every omitted entry retains its packaged value, when present.

For example, this setting changes only the CPU request:

```yaml
manager:
  resources:
    requests:
      cpu: 150m
```

An omitted `manager`, omitted `resources`, empty resource object, or empty map preserves the packaged defaults.
An explicit zero is a supplied quantity.
It must satisfy validation.
Settings remain stored when `enabled: false`, without creating a workload.

Remove an override to restore that entry's packaged value.
If the packaged manifest has no value, WAO removes the field that it previously managed.
Removing an override cannot remove an existing packaged default.
This API has no separate operation to clear packaged defaults.
An operand update can change the packaged value of an omitted entry.

A partial setting can conflict with a packaged default.
For example, Storage Based Remediation currently requests `64Mi` of memory.
A memory limit of `32Mi` alone conflicts with that request.
Also reduce the request if you require that limit.

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

## Validation and status

The Kubernetes API checks each value with a CEL `isQuantity` rule.
The rule rejects exponents longer than three digits, such as `1e1000`, before it parses the value.
This requires Kubernetes 1.29 or later.
Use CPU quantities such as `100m` or `1`.
Use memory quantities such as `128Mi` or `1Gi`.
String values for `enabled`, including `"true"`, are invalid.
The resource schema declares only `cpu` and `memory` entries.
Strict field validation rejects other resource names.
Kubernetes can remove unknown entries when the client does not request strict validation.

WAO checks resource values when it reconciles an enabled component.
WAO rejects these settings:

- Negative quantities.
- An effective request greater than its effective limit.

The effective values combine your overrides with the packaged defaults.
WAO reports invalid settings in the component's `Degraded` status.
The message identifies the configuration path and the conflicting values.
For example:

```text
spec.components.storageBasedRemediation.manager.resources.requests.memory: effective request 64Mi exceeds effective limit 32Mi
```

WAO does not apply that component's objects when its resource settings are invalid.
The last valid Deployment configuration remains in place.
Other components continue to reconcile.
Correct the settings to resume normal reconciliation.
You can disable or delete the configuration even when its resource settings are invalid.
WAO defers these resource checks while the component is disabled.

