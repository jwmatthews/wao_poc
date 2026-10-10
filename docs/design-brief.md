# Design brief: a single Workload Availability Operator

Status: proof-of-concept design, October 2026. Not an approved product design.

## 1. Problem

The six medik8s workload availability components are installed today as
independent OLM packages. Node Health Check (NHC) decides that a node needs
remediation and creates a remediation request from a template. Self Node
Remediation (SNR), Storage Based Remediation (SBR), Fence Agents Remediation (FAR)
and Machine Deletion Remediation (MDR) carry requests out. Node Maintenance (NMO)
cordons and drains nodes on explicit request. Each package has its
own CSV, its own API ownership, its own upgrade decision and its own status.

An administrator who wants "node remediation" therefore installs and upgrades
several operators, with no single place to see what is configured, which versions
work together, or whether protection is actually in place.

## 2. Approach

Build one **Workload Availability Operator (WAO)**:

- **One OLM package and one CSV** own the component CRDs, unchanged, plus a new
  cluster-scoped `WorkloadAvailabilityConfig` singleton named `cluster`.
- **One lifecycle controller** installs each component's existing controller-manager
  as a **separate operand**, from that component's published bundle and image, when
  the administrator enables it.
- **A tested release set** pins the component versions that ship together.

The component APIs, remediation protocols and controller responsibilities stay as
they are. NHC still decides when to remediate; SNR, SBR, FAR and MDR still execute;
NMO still performs maintenance; SNR and SBR node agents still exist. This POC proves the packaging and lifecycle layer only.

## 3. Alternatives considered

| Approach | Benefit | Cost | Verdict |
| --- | --- | --- | --- |
| Umbrella operator that creates the existing Subscriptions | Little new code | Still several CSVs, API owners and upgrade lifecycles | Useful installer, not consolidation |
| **One bundle, lifecycle controller, separate operands** | One API owner and release; process boundaries preserved | Needs operand manifests, admission wiring and lifecycle handling | **POC target** |
| Merge all controllers into one binary | Fewer processes | Couples dependencies, caches, privileges and failures; agents still exist | Deferred |
| One universal remediation API | Simpler user model eventually | Changes every API and integration at once | Deferred |

## 4. Ownership model

OLM API ownership, Kubernetes owner references and field ownership are separate
concepts. The POC defines each explicitly.

| Resource | Authority |
| --- | --- |
| Component CRDs and the WA config CRD | The WAO CSV, whether or not the component is enabled |
| WAO's own Deployment | OLM, from the CSV install strategy |
| Component manager Deployments, Services, service accounts and RBAC | WAO, via server-side apply with field owner `workload-availability-operator` |
| Objects the components create at runtime (agent DaemonSets, default configs, templates, certificates) | The component, exactly as in a standalone install |
| Administrator-created policies, templates, configs and Secrets | The administrator; WAO never adopts or deletes them |

WAO sets a controller owner reference from the singleton config to each operand
object it renders, so garbage collection and change watches work. It never sets
owner references on administrator objects.

## 5. Admission

The components register admission webhooks. With OLM, webhook certificates are
normally injected for Deployments that the CSV itself defines
([OLM webhook docs](https://olm.operatorframework.io/docs/advanced-tasks/adding-admission-and-conversion-webhooks/)).
Here WAO, not the CSV, creates the component Deployments, so OLM cannot inject
certificates for them.

The four upstream managers that serve webhooks look for OLM-injected certificates
first and otherwise fall back to the controller-runtime default certificate directory
([NHC](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/cmd/main.go#L300-L322),
[SNR](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/cmd/main.go#L412-L436),
[FAR](https://github.com/medik8s/fence-agents-remediation/blob/78139f2f3c2e2611863ae3bce25ac5b375d78d97/cmd/main.go#L196-L216),
[NMO](https://github.com/medik8s/node-maintenance-operator/blob/3a54cd157723cd555ebd792c52e8d363d9df6dd3/cmd/main.go#L192-L212)). SBR and MDR serve no webhooks at these releases. The POC uses
that fallback with OpenShift's service CA: the webhook Service gets a
`service.beta.openshift.io/serving-cert-secret-name` annotation, the Secret is
mounted at `/tmp/k8s-webhook-server/serving-certs`, and the webhook configuration
gets `service.beta.openshift.io/inject-cabundle: "true"`.

The better long-term shape is a CSV-installed admission backend that stays up even
when a component is disabled. That needs webhook-only and controller-only modes in
the components, which is a component change and out of scope here.

## 6. Configuration

```yaml
apiVersion: workloadavailability.medik8s.io/v1alpha1
kind: WorkloadAvailabilityConfig
metadata:
  name: cluster
spec:
  components:
    nodeHealthCheck:
      state: Enabled
    selfNodeRemediation:
      state: Disabled
    storageBasedRemediation:
      state: Disabled
    fenceAgentsRemediation:
      state: Disabled
    machineDeletionRemediation:
      state: Disabled
    nodeMaintenance:
      state: Enabled
```

- Every component defaults to `Disabled`.
- The config carries intent only. Component-specific settings stay in the native
  component resources, such as `NodeHealthCheck` and `SelfNodeRemediationConfig`.
- Status reports per-component phase, operand readiness, admission readiness,
  retained resources and the pinned release set.

## 7. What Enabled and Disabled mean

Enabling a component renders and applies its operand objects. Status becomes
`Available` when the manager Deployments are ready and, for components with
webhooks, the webhook CA bundles are injected.

Disabling a component removes the operand objects WAO created. It does **not**
stop everything the component created:

- SNR's manager creates its default `SelfNodeRemediationConfig` at startup
  ([source](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/snrconfighelper/configinitializer.go#L28-L48)), and the
  config controller creates the agent DaemonSet owned by that config
  ([source](https://github.com/medik8s/self-node-remediation/blob/79fb792830c6db78b0dab45c45f5b79591118c76/internal/controller/selfnoderemediationconfig_controller.go#L203)).
- SBR's config controller creates the agent DaemonSet, PVC and Jobs owned by each
  `StorageBasedRemediationConfig`
  ([source](https://github.com/medik8s/storage-based-remediation/blob/3d76c00102d28327b8ca7e31ea68dd915c9526a4/internal/controller/storagebasedremediationconfig_controller.go#L1096-L1116)).

Removing a manager therefore leaves agents running. Native objects the manager
reconciles can also be stranded. Examples:
- An active `NodeMaintenance` keeps its node cordoned with nobody to finish or undo it.
- FAR, MDR, SNR and SBR remediation objects lose the controller that would complete
  them and remove their finalizers.

WAO reports all of these as phase `DisableIncomplete` with the retained objects
listed, rather than claiming the component is off. Safely stopping node agents is a component-level procedure and
out of scope for the POC.

## 8. POC decisions

| # | Decision | Reason | Long-term direction |
| --- | --- | --- | --- |
| D1 | WAO-managed managers serve their own webhooks using service-ca certificates (section 5) | Works with unchanged component images | CSV-installed admission backends |
| D2 | Disabling a component also removes its webhook configurations | A `Fail` webhook without a backend would block even deleting the component's objects; switching to `Ignore` silently drops validation | Admission that stays available while disabled |
| D3 | Enabling SNR behaves like a standalone SNR install: the default config, default template and agent DaemonSet appear and agents run on every eligible node | SNR has no "installed but inactive" mode | A component-supported managed mode |
| D4 | WAO creates an all-Disabled `cluster` config at startup if none exists, and never overwrites an existing one | One status object right after install, with no side effects | Same |
| D5 | Disable is manager-level; retained agents and configs are reported as `DisableIncomplete` | The manager does not own the agents (section 7) | Component shutdown procedures |
| D6 | The catalog is a file-based catalog (FBC) image served by an OLM v1 `ClusterCatalog` named `wao-poc` | OLM v1's `ClusterCatalog` accepts only images; catalogd needs nothing but the FBC files under the labelled directory | Same |
| D7 | WAO's operand ClusterRole is the union of every rule of every Role and ClusterRole WAO renders (the CSV `permissions` and `clusterPermissions` and the bundle-shipped roles alike), plus the rules WAO itself needs, including RBAC `bind`. WAO also grants each CSV's namespaced `permissions` cluster-wide (a `<serviceaccount>-all-namespaces` ClusterRole and ClusterRoleBinding), as OLM does for an OperatorGroup that targets all namespaces, the only install mode the component CSVs support; like OLM, it appends get/list/watch on `namespaces` to that ClusterRole | Kubernetes RBAC escalation prevention: WAO can only grant what it holds. Components must see the effective RBAC of a standalone OLM install; FAR, for example, lists Secrets cluster-wide | Same, audited |
| D8 | The POC CSV owns all twelve component CRDs plus the WA config CRD, whether or not a component is enabled | One API owner per cluster; standalone installs of these operators cannot coexist with WAO | Same |
| D9 | Placeholder namespaces left in bundle RBAC subjects (for example `sbr-operator-system`) are rewritten to the install namespace | OLM rewrites CSV-defined subjects; WAO must do the same for objects it renders | Same |
| D10 | Every operand pod gets the label `workloadavailability.medik8s.io/component=<key>`. A Service whose upstream selector also matches another component's pods gets that label added to its selector. At these releases only MDR's metrics Service is affected | All six managers share one namespace, and MDR's upstream selector is only `control-plane: controller-manager`, a label every other manager pod also carries | Component-specific selectors upstream |
| D11 | OLM v1 (`ClusterExtension`) is the only install path; the classic OLM path (ConfigMap `CatalogSource`, `OperatorGroup`, `Subscription`, `InstallPlan`) is removed from the repository | The bundle already meets OLM v1's content rules; OLM v1 is GA and default-on from OpenShift 4.18; WAO's runtime-created component webhooks (D1) sidestep OLM v1's webhook limitations on 4.18–4.20; one path is one less thing to keep in parity | Same |
| D12 | Installer RBAC (ServiceAccount `wao-installer`, ClusterRole, ClusterRoleBinding) is generated from the CSV, committed under `config/olmv1/wao/` and always applied | Required on OpenShift 4.18–4.22; accepted with a deprecation warning and ignored on 5.0, where operator-controller runs as cluster-admin | Drop when every supported release ignores `spec.serviceAccount` |

## 9. Non-goals for the POC

- Upgrades, `OperatorCondition` upgrade gating and persisted rollout plans
  ([OLM operator conditions](https://olm.operatorframework.io/docs/advanced-tasks/communicating-operator-conditions-to-olm/)).
  These are the next plan.
- Migration or adoption of existing standalone installations.
- Component changes of any kind.
- Remediation and maintenance behavior. The POC tests installation and lifecycle,
  not whether a node is actually fenced, deleted, drained or rebooted.
- Uninstall safety beyond what OLM provides
  ([OLM uninstall](https://olm.operatorframework.io/docs/tasks/uninstall-operator/)):
  deleting the CSV does not stop node agents.

## 10. What success looks like

On a clean OpenShift cluster with classic OLM:

1. WAO installs from its catalog and owns the thirteen CRDs.
2. Nothing component-related runs until enabled.
3. Enabling each of the six components yields operand Deployments and RBAC
   identical to the upstream bundle, apart from the documented certificate wiring
   and component label, and working admission.
4. Every operand Service selects only its own component's pods.
5. Disable and config deletion behave as described in sections 7 and 8, and status
   tells the truth about what is left.
