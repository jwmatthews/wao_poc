# Operand configuration and Kustomize overlays

The Workload Availability Operator (WAO) installs six medik8s operators as operands.
An operand is a component operator that WAO installs without modification.

WAO copies each operand's upstream `config/` directory without changes.
Kustomize overlays select and adjust the copied resources.
An overlay is a Kustomize configuration that applies changes to a base configuration.

WAO uses two overlays for each operand:

- The `rbac` overlay selects permissions that WAO needs at installation.
- The `runtime` overlay adjusts resources that WAO creates when a component becomes `Enabled`.

## Why WAO copies the upstream configuration

Each operand defines its Deployments, Services, webhooks, permissions, and custom resource definitions (CRDs) in its own `config/` directory.
These definitions change when the operand changes.

Separate definitions in WAO's Go code or manually maintained copies could differ from the upstream configuration.
WAO must consume component operators without modification.

The `make update-<key>-manifests` command copies the complete operand `config/` directory from a local checkout.
It replaces `config/operands/<key>/config/` on each update.
WAO does not edit files in that directory.

See [Updating operand manifests](updating-operand-manifests.md) for the update procedure.

## Why WAO separates the copied resources

The copied `config/` directory contains resources that the operand's own `make bundle` command would package for a separate installation.
WAO must handle these resources as follows:

| Copied resource | WAO action |
| --- | --- |
| CRDs | Include them in WAO's bundle. Operator Lifecycle Manager (OLM) installs them with WAO. |
| ServiceAccounts, Roles, and role bindings | Include them in WAO's ClusterServiceVersion (CSV). OLM creates them at installation. |
| Manager Deployments, Services, ConfigMaps, and webhook configurations | Create them only when the component becomes `Enabled`. Every component defaults to `Disabled`. |
| The operand's CSV, Namespace, sample custom resource, and scorecard configuration | Exclude them from WAO's package. |

A CSV describes an operator and the permissions that OLM must create for it.
Role-based access control (RBAC) defines the permissions that ServiceAccounts receive through roles and role bindings.

A separate OLM installation connects the OpenShift service-ca controller to the webhook resources.
The service-ca controller provides service certificates and a certificate authority (CA) bundle.
WAO must configure these connections itself.

The six managers share one namespace.
WAO must add a component label to each pod template and Service selector.
Otherwise, some upstream selectors can select pods from other managers.

WAO separates the resources by their creation stage and the tool that creates them.
The overlays apply the required changes without editing the copied files.

## The two overlays

Each operand has WAO overlays beside its copied configuration:

```text
config/operands/<key>/
  config/                 # Upstream copy. Each update replaces this directory.
  overlays/
    rbac/                 # Permissions for WAO's CSV at installation.
    runtime/              # Resources for a component that is Enabled.
```

Both overlays use the same copied base configuration.
NHC uses its OpenShift overlay, `config/manifests/ocp`.
The other operands use `config/default`.

The overlays select different resource kinds and apply different changes.
An update replaces the copied configuration but preserves the overlays.

CRDs use a separate path without an overlay.
The file `config/operands/crd/kustomization.yaml` lists the six copied `config/crd` directories.
WAO's `config/crd` includes that file.

### Permissions at installation: `overlays/rbac`

The `rbac` overlay keeps only these resource kinds:

- ServiceAccount
- Role
- RoleBinding
- ClusterRole
- ClusterRoleBinding

The overlay deletes each other kind with a `$patch: delete` entry.
If an upstream binding does not meet WAO's packaging requirements, an overlay patch changes the binding.

For example, NHC's overlay binds a Role in `kube-system` to the operand's ServiceAccount, whose name includes a prefix.
This lets operator-sdk include the Role in the CSV.
Otherwise, operator-sdk emits a namespaced object that OLM cannot create in `kube-system`.

The `make bundle` command processes the permissions as follows:

1. It runs `kustomize build config/manifests`. That configuration includes all six `overlays/rbac` directories as resources.
2. It sends the result to `operator-sdk generate bundle`.
3. It passes the operand ServiceAccounts through `--extra-service-accounts`. The Makefile variable `OPERAND_SERVICE_ACCOUNTS` lists these accounts.

The operator-sdk tool includes the roles bound to those ServiceAccounts in the CSV's permissions.
OLM creates these resources when it installs WAO, even if no component becomes `Enabled`.

The `make verify-operand-manifests` command checks that each `rbac` overlay produces only RBAC resource kinds.
It also checks that the Makefile lists every operand ServiceAccount.

### Resources for enabled components: `overlays/runtime`

The `runtime` overlay applies these changes to the copied base configuration:

- It sets `namespace: __WAO_NAMESPACE__`. The operator replaces this placeholder when it reconciles the component.
- It uses `images:` entries to replace each upstream image with `__WAO_<ENV>__:placeholder`. The operator replaces each token with the corresponding `RELATED_IMAGE_<...>` value from its environment.
- It patches the manager environment variables for SNR's self-image and SBR's agent image. These patches use the same image tokens.
- It adds the `workloadavailability.medik8s.io/component` label to each Deployment pod template and Service selector.
- It connects OpenShift service-ca to the webhook Service and the manager's certificate volume. It also configures CA injection for the webhook configuration.

Reconciliation is the process in which the operator compares the requested configuration with the cluster resources and applies the required changes.

The `make operand-manifests` command generates the runtime manifests as follows:

1. It runs `kustomize build config/operands/<key>/overlays/runtime`.
2. It keeps only the resource kinds in the Makefile variable `RUNTIME_KINDS`.
3. It writes the result to `internal/operands/manifests/<key>/objects.yaml`.

The permitted kinds are Deployment, Service, ConfigMap, ValidatingWebhookConfiguration, and MutatingWebhookConfiguration.

The command fails if any `image:` field contains a value other than a WAO placeholder.
This check prevents WAO from deploying an upstream default image that has no WAO mapping.
The WAO binary includes the generated file through `go:embed`.

When a component is `Enabled`, `internal/operands/render.go` prepares the embedded objects:

1. It loads the objects.
2. It replaces the namespace and image placeholders.
3. It adds the managed-by and component labels.
4. It orders Services before Deployments and places webhooks last.

The controller applies the objects with server-side apply.
When the component returns to `Disabled`, the controller removes the same set of objects.
WAO creates none of these runtime resources until the component becomes `Enabled`.

## Where to make a change

| Required change | Action |
| --- | --- |
| Copy updated upstream configuration | Run `make update-<key>-manifests`. The command replaces `config/operands/<key>/config/`. |
| Select a different operand image | Edit `operands.yaml`. Run `make operand-manifests`. |
| Change the operand permissions in WAO's CSV | Edit `config/operands/<key>/overlays/rbac/`. |
| Change how an operand runs in WAO's namespace | Edit `config/operands/<key>/overlays/runtime/`. |
| Change a copied file | Apply the change through an overlay. Do not edit the copy. The next update replaces it. |

If an upstream resource name changes, its overlay patch can fail.
In that case, `kustomize build` fails during `make operand-manifests` or `make bundle`.
Use this failure to identify the overlay that needs a change.
