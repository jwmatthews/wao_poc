# Configure operand manager resources

WAO uses `WorkloadAvailabilityConfig/cluster` to configure its six component operators.
Each component has a boolean `enabled` field.
The default is `false`.
An omitted component or enable field remains disabled.
Use `true` and `false` without quotes.

Set `spec.components.<key>.manager.resources` to configure the selected manager container.
The field uses Kubernetes `ResourceRequirements`, with `requests` and `limits` maps.
WAO supports CPU and memory only.
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

## Use the OpenShift console

WAO normally creates the singleton named `cluster` when it starts.
Edit this existing object when it is present.
Each component section provides an Enabled switch and Manager Resources controls.
These controls use boolean values and Kubernetes resource quantities.

1. Open the installed Workload Availability Operator in the OpenShift console.
2. Select its `WorkloadAvailabilityConfig` resource.
3. Open the existing `cluster` object.
4. Select the form editor.
5. Set the component's Enabled switch as required.
6. Enter CPU or memory quantities in its Manager Resources controls.
7. Save the object.
8. Check the component status and its manager Deployment.

If the singleton is absent, use the console's Create form.
Keep the required name `cluster`.
The initial example sets all six components to `enabled: false`.
The creation form provides the same switches and resource controls.
WAO does not accept other configuration names.

Enabling Self Node Remediation starts privileged node agents on eligible nodes.
Disabling a component removes its manager and managed installation resources.
Existing agents, native configuration, and remediation objects can remain.
Complete active maintenance or remediation before disabling a component.

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

## Validation and status

The Kubernetes API checks the quantity structure.
Use CPU quantities such as `100m` or `1`.
Use memory quantities such as `128Mi` or `1Gi`.
String values for `enabled`, including `"true"`, are invalid.

WAO checks resource values when it reconciles an enabled component.
WAO rejects these settings:

- Negative quantities.
- Resource names other than `cpu` and `memory`.
- Nonempty resource `claims`.
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

Cluster policies still apply.
A `LimitRange` or `ResourceQuota` can reject a Deployment or its Pods.
WAO preserves Deployment API errors in status.
If Deployment creation succeeds but Pod creation fails, the component can remain `Progressing`.
Resource validation does not check cluster capacity.

## Scope and rollout

These settings affect only the named manager container in each component's manager Deployment.
They do not configure these resources:

- The WAO manager.
- The NHC console plugin.
- Sidecars or init containers.
- Agent DaemonSets or other workloads that the operands create.
- Operand-native configuration objects.

A resource change updates the manager's Pod template.
The Deployment uses its existing rollout strategy.
WAO does not require a separate restart command.
WAO also repairs changes to resource values that it manages.

## Check the effective resources

Set `KUBECONFIG` to your cluster's kubeconfig path.
Use the namespace from `status.installNamespace` if it differs from the namespace below.

Check the configuration and component status:

```sh
oc --kubeconfig "$KUBECONFIG" get workloadavailabilityconfig cluster -o yaml
```

Check the NHC manager's effective resources:

```sh
oc --kubeconfig "$KUBECONFIG" get deployment node-healthcheck-controller-manager \
  -n openshift-workload-availability \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].resources}{"\n"}'
```

Check the manager rollout:

```sh
oc --kubeconfig "$KUBECONFIG" rollout status deployment/node-healthcheck-controller-manager \
  -n openshift-workload-availability
```

The configuration shows the supplied overrides.
The Deployment shows the effective values after WAO merges the packaged defaults.

## Migrate an existing configuration

Replacing `state` with `enabled` breaks the previous `v1alpha1` input format.
WAO does not support both fields.
Status can still use `Enabled` and `Disabled` as state names.
These status values are separate from the new boolean input.

Convert every saved component entry:

| Previous input | New input |
| --- | --- |
| `state: Enabled` | `enabled: true` |
| `state: Disabled` | `enabled: false` |
| Omitted state | `enabled: false`, or omit the field |

Remove each old `state` field after conversion.
Preserve resource settings and all unrelated fields.

Existing installations require a controlled upgrade.
A new controller can interpret an old `state: Enabled` entry as disabled.
Do not start the new controller before the converted configuration is installed.

1. Export and preserve the current configuration before changing the CRD.
2. Convert the saved component entries with the table above.
3. Stop reconciliation by the old controller during the upgrade.
4. Prevent OLM from starting the new controller before conversion completes.
5. Install the new CRD schema.
6. Install the converted configuration.
7. Check that the stored enable fields contain the intended booleans.
8. Start the new controller.
9. Check each component's status and manager Deployment.

Use your installation's upgrade procedure to control controller startup and OLM updates.
Patching `enabled` into the old CRD is insufficient.
Kubernetes can remove fields that the old schema does not define.
This change does not provide an unattended migration.
Use fresh disposable installations for console creation tests.
