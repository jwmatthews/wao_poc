# OLM v1 (operator-controller) install, RBAC, upgrade, removal and OLM v0 migration — cluster-admin and operator-author view (state as of 2026-10-10)

Scope note on versions used throughout these notes:

- **Upstream operator-controller**: `main` as of 2026-10-10, and tagged releases v1.4.0 (2025-08-15), v1.6.0 (2025-11-11), v1.7.0 (2025-11-24), v1.8.0 (2026-02-19), v1.9.0 (2026-06-08), v1.10.0 (2026-06-11), v1.11.0 (2026-07-23), v1.12.0 (2026-09-24). Dates are the GitHub `published_at` values from [GitHub releases API](https://github.com/operator-framework/operator-controller/releases).
- **OpenShift**: the Red Hat "Extensions" guide for OCP 4.20, 4.21 and 4.22 (all published on docs.redhat.com as of 2026-10-10), and the OpenShift fork branches `release-4.19` … `release-4.22` of [openshift/operator-framework-operator-controller](https://github.com/openshift/operator-framework-operator-controller).
- **The single most important version split**: on upstream `main` / v1.11.0+ the `spec.serviceAccount` field is **deprecated and ignored** and operator-controller runs as **cluster-admin**; on every shipped OpenShift release branch through `release-4.22` the field is still **required** and the installer ServiceAccount model (plus the Tech Preview "preflight permissions check") still applies. Both models are documented below, each tagged with the versions it applies to.

---

## Key question 1: Installer ServiceAccount and RBAC — what the SA needs, the "derive minimal RBAC" procedure, why, and the 2026 automation/feature-gate status

### Takeaway
On OpenShift 4.18–4.22 (and upstream ≤ v1.10) the ClusterExtension must name an installer ServiceAccount that holds *every* permission the bundle will create or grant (CRDs, (Cluster)Roles/(Cluster)RoleBindings, Deployment, SA, Services, ConfigMaps, the CSV's `permissions`/`clusterPermissions`, plus `clusterextensions/finalizers` update), because operator-controller does not use cluster-admin and Kubernetes RBAC escalation prevention requires the creator of a role to already hold (or be able to `escalate`/`bind`) the permissions it grants. Upstream reversed this model in July 2026 (operator-controller v1.11.0, PR #2770, OpenShift enhancement "service-account-deprecation"): `spec.serviceAccount` is now deprecated and silently ignored, operator-controller runs with `cluster-admin`, and the `PreflightPermissions` and `SyntheticPermissions` feature gates were deleted; access control moves to RBAC on *who may write ClusterExtensions* plus ValidatingAdmissionPolicy. No shipped OpenShift release (through 4.22 docs) has adopted that change yet.

### Cited Findings

**Why the installer SA exists (pre-deprecation model, upstream ≤ v1.10, OCP 4.18–4.22):**
- "OLM v1 does not have permission to install extensions on a cluster by default. In order to install a supported bundle, OLM must be provided a ServiceAccount configured with the appropriate permissions." — [upstream docs/howto/derive-service-account.md at tag v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/howto/derive-service-account.md)
- "OLMv1 itself does not have cluster-wide admin permissions. Therefore, each cluster extension must specify a service account with sufficient permissions to install and manage it. … the cluster extension service account's privileges would be a superset of the privileges required by the service account in the bundle." and "Since the extension bundle contains its own RBAC, it means the ClusterExtension service account requires either: the same set of permissions that are defined in the RBAC that it is trying to create. [or] bind/escalate verbs for RBAC, see https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping" — [upstream docs/concepts/permission-model.md at v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/concepts/permission-model.md)
- "**Note**: The ClusterExtension permissions are not propogated to the deployment. The ClusterExtension service account and the bundle's service accounts have different purposes and naming conflicts between the two service accounts can lead to failure of ClusterExtension deployment." — [permission-model.md v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/concepts/permission-model.md)
- Red Hat (OCP 4.20): "In Operator Lifecycle Manager (OLM) Classic, a single service account with cluster administrator privileges manages all cluster extensions. OLM v1 is designed to be more secure than OLM (Classic) by default. OLM v1 manages a cluster extension by using the service account specified in an extension's custom resource (CR). Cluster administrators can create a service account for each cluster extension. As a result, administrators can follow the principle of least privilege …" and "If a new version of an installed extension requires additional permissions, OLM v1 halts the update process until a cluster administrator grants those permissions." — [OCP 4.20 Extensions guide, §5.1.3 "Cluster extension permissions"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- The 4.21 and 4.22 Extensions guides keep the identical procedure (sections 5.2.2.1–5.2.2.7 "Creating a namespace", "Creating a service account for an extension", "Downloading the bundle manifests of an extension", "Required permissions to install and manage a cluster extension", "Creating a cluster role for an extension", "Example cluster role for the Red Hat OpenShift Pipelines Operator", "Creating a cluster role binding for an extension"). — [OCP 4.21 Extensions guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/extensions/cluster-extensions); [OCP 4.22 Extensions guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- API field text on every OpenShift release branch 4.19–4.22: "serviceAccount specifies a ServiceAccount used to perform all interactions with the cluster that are required to manage the extension. The ServiceAccount must be configured with the necessary permissions to perform these interactions. The ServiceAccount must exist in the namespace referenced in the spec. The serviceAccount field is required. // +required ServiceAccount ServiceAccountReference `json:"serviceAccount"`" — [openshift fork release-4.22 api/v1/clusterextension_types.go](https://github.com/openshift/operator-framework-operator-controller/blob/release-4.22/api/v1/clusterextension_types.go) (same wording verified on release-4.19, release-4.20, release-4.21).

**Red Hat's exact "required permissions" checklist (OCP 4.20 §5.1.3.4; identical in 4.21/4.22):**
- "Admission plugins — Because OpenShift Container Platform clusters use the OwnerReferencesPermissionEnforcement admission plugin, cluster extensions must have permissions to update the blockOwnerDeletion and ownerReferences finalizers."
- "Cluster role and cluster role bindings for the controllers of the extension — You must define RBAC so that the installation service account can create and manage cluster roles and cluster role bindings for the extension controllers."
- "Cluster service version (CSV) — You must define RBAC for the resources defined in the CSV of the cluster extension."
- "Cluster-scoped bundle resources — You must define RBAC to create and manage any cluster-scoped resources included in the bundle…"
- "Custom resource definitions (CRDs) — You must define RBAC so that the installation service account can create and manage the CRDs for the extension. Also, you must grant the service account for the controller of the extension the RBAC to manage its CRDs."
- "Deployments — You must define RBAC for the installation service account to create and manage the deployments needed by the extension controller, such as services and config maps."
- "Extension permissions — You must include RBAC for the permissions and cluster permissions defined in the CSV. The installation service account needs the ability to grant these permissions to the extension controller…"
- "Namespace-scoped bundle resources …", "Roles and role bindings …", "Service accounts — You must define RBAC so that the installation service account can create and manage the service accounts for the extension controllers."
- "You cannot scope the create, list, and watch verbs to specific resource names (the resourceNames field). You must scope these permissions to their resources (the resources field)." and "The resource names in the resourceNames field for the get, update, patch, and delete verbs are generated by using the following format: `<package_name>.<hash>`. After you install the extension, look up the resource names for the cluster roles and cluster role bindings for the controller of the extension. Replace the wildcard characters in this example with the generated names and follow the principle of least privilege." — all from [OCP 4.20 Extensions guide §5.1.3.4–5.1.3.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)

**Red Hat procedure, verbatim YAML and commands (OCP 4.20 §5.1.3.x):**
- Namespace: `$ oc adm new-project <new_namespace>`
- ServiceAccount:
  ```yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: <extension>-installer
    namespace: <namespace>
  ```
  (example `pipelines-installer` in namespace `pipelines`; applied with `$ oc apply -f extension-service-account.yaml`)
- Find bundle images to inspect:
  ```
  $ opm render <registry_url>:<tag_or_version> | \
    jq -cs '.[] | select( .schema == "olm.bundle" ) | \
    select( .package == "<extension_name>") | \
    {"name":.name, "image":.image}'
  ```
  then `$ mkdir <new_dir>`, `$ cd <new_dir>`, `$ oc image extract <full_path_to_registry_image>@sha256:<sha>`, `$ cd manifests`, `$ tree`, and "View the contents of the install.spec.clusterpermissions stanza of cluster service version (CSV) file in the manifests directory".
- **"Quick cluster-admin for testing" variant (Red Hat):** "If you want to test the process for installing and updating an extension in OLM v1, you can use the following cluster role to grant cluster administrator permissions. This manifest is for testing purposes only. It should not be used in production clusters."
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: <extension>-installer-clusterrole
  rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  ```
- **Least-privilege ClusterRole, Red Hat excerpts** (OpenShift Pipelines example):
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: pipelines-installer-clusterrole
  rules:
  - apiGroups:
    - olm.operatorframework.io
    resources:
    - clusterextensions/finalizers
    verbs:
    - update
    # Scoped to the name of the ClusterExtension
    resourceNames:
    - <metadata_name>
  ```
  ```yaml
  # ClusterRoles and ClusterRoleBindings for the controllers of the extension
  - apiGroups:
    - rbac.authorization.k8s.io
    resources:
    - clusterroles
    verbs:
    - create
    - list
    - watch
  - apiGroups:
    - rbac.authorization.k8s.io
    resources:
    - clusterroles
    verbs:
    - get
    - update
    - patch
    - delete
    resourceNames:
    - "*"
  - apiGroups:
    - rbac.authorization.k8s.io
    resources:
    - clusterrolebindings
    verbs:
    - create
    - list
    - watch
  - apiGroups:
    - rbac.authorization.k8s.io
    resources:
    - clusterrolebindings
    verbs:
    - get
    - update
    - patch
    - delete
    resourceNames:
    - "*"
  ```
  ```yaml
  # Custom resource definitions of the extension
  - apiGroups:
    - apiextensions.k8s.io
    resources:
    - customresourcedefinitions
    verbs:
    - create
    - list
    - watch
  - apiGroups:
    - apiextensions.k8s.io
    resources:
    - customresourcedefinitions
    verbs:
    - get
    - update
    - patch
    - delete
    resourceNames:
    - manualapprovalgates.operator.tekton.dev
    - openshiftpipelinesascodes.operator.tekton.dev
    - tektonaddons.operator.tekton.dev
    - tektonchains.operator.tekton.dev
    - tektonconfigs.operator.tekton.dev
    - tektonhubs.operator.tekton.dev
    - tektoninstallersets.operator.tekton.dev
    - tektonpipelines.operator.tekton.dev
    - tektonresults.operator.tekton.dev
    - tektontriggers.operator.tekton.dev
  ```
  ```yaml
  # Excerpt from install.spec.deployments
  - apiGroups:
    - apps
    resources:
    - deployments
    verbs:
    - create
    - list
    - watch
  - apiGroups:
    - apps
    resources:
    - deployments
    verbs:
    - get
    - update
    - patch
    - delete
    # scoped to the extension controller deployment name
    resourceNames:
    - openshift-pipelines-operator
    - tekton-operator-webhook
  ```
  ```yaml
  # Services
  - apiGroups:
    - ""
    resources:
    - services
    verbs:
    - create
  - apiGroups:
    - ""
    resources:
    - services
    verbs:
    - get
    - list
    - watch
    - update
    - patch
    - delete
    # scoped to the service name
    resourceNames:
    - openshift-pipelines-operator-monitor
    - tekton-operator
    - tekton-operator-webhook
  # configmaps
  - apiGroups:
    - ""
    resources:
    - configmaps
    verbs:
    - create
  - apiGroups:
    - ""
    resources:
    - configmaps
    verbs:
    - get
    - list
    - watch
    - update
    - patch
    - delete
    # scoped to the configmap name
    resourceNames:
    - config-logging
    - tekton-config-defaults
    - tekton-config-observability
    - tekton-operator-controller-config-leader-election
    - tekton-operator-info
    - tekton-operator-webhook-config-leader-election
  ```
  plus a copy of every rule in the CSV's `install.spec.clusterPermissions` and `install.spec.permissions` ("Search the CSV file for stanzas with the permissions and clusterPermissions values in the rules.resources spec. Copy the API groups, resources, verbs, and resource names to your manifest"). Apply with `$ oc apply -f pipelines-installer-clusterrole.yaml`.
- ClusterRoleBinding:
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: <extension>-installer-binding
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: <extension>-installer-clusterrole
  subjects:
  - kind: ServiceAccount
    name: <extension>-installer
    namespace: <namespace>
  ```
  — all from [OCP 4.20 Extensions guide §5.1.3.1–5.1.3.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions). Red Hat's note: "To simply the following procedure and improve readability, the following example manifest uses permissions that are scoped to the cluster. You can further restrict some of the permissions by scoping them to the namespace of the extension instead of the cluster."

**Upstream "derive minimal ServiceAccount" procedure (docs at tag v1.10.0; removed from `main` after the deprecation):**
- The SA "must have permissions to: create and manage the extension's CustomResourceDefinitions; create and manage the resources packaged in the bundle; grant the extension controller's service account the permissions it requires for its operation; create and manage the extension controller's service account; create and manage the Roles, RoleBindings, ClusterRoles, and ClusterRoleBindings associated with the extension controller's service account; create and manage the extension controller's deployment" and, for OwnerReferencesPermissionEnforcement clusters, "update finalizers on the ClusterExtension to be able to set blockOwnerDeletion and ownerReferences". "Keep in mind, that it is not possible to scope create, list, and watch permissions to specific resource names." — [derive-service-account.md v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/howto/derive-service-account.md)
- Upstream ClusterRole step 1 (RBAC management):
  ```yaml
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles]
    verbs: [create, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles]
    verbs: [get, update, patch, delete]
    resourceNames: [<controller cluster role name 1>, ...]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterrolebindings]
    verbs: [create, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterrolebindings]
    verbs: [get, update, patch, delete]
    resourceNames: [<controller cluster rolebinding name 1>, ...]
  ```
  "These names are generated with the following format: `<packageName>.<hash>`. Since it is not a trivial task to generate these names ahead of time, it is recommended to use a wildcard `*` in the `resourceNames` field for the installation. Then, update the `resourceNames` fields by inspecting the cluster for the generated resource names." Example generated names: `argocd-operator.v0-1dhiybrldl1gyksid1dk2dqjsc72psdybc7iyvse5gpx`. — same source
- Step 2 (CRDs):
  ```yaml
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [create, list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, update, patch, delete]
    # Scoped to the CRDs in the bundle
    resourceNames: [applications.argoproj.io, appprojects.argoproj.io, argocds.argoproj.io, argocdexports.argoproj.io, applicationsets.argoproj.io]
  ```
- Step 3 (OwnerReferencesPermissionEnforcement):
  ```yaml
  - apiGroups: [olm.operatorframework.io]
    resources: [clusterextensions/finalizers]
    verbs: [update]
    # Scoped to the name of the ClusterExtension
    resourceNames: [argocd-operator.v0.6.0]
  ```
- Step 4: add any bundled cluster-scoped objects (e.g. the bundled `argocd-operator-metrics-reader` ClusterRole) to the `resourceNames` of the existing rule. Step 5: "Include all permissions defined in the `.spec.install.permissions` and `.spec.install.clusterPermissions` stanzas in the bundle's ClusterServiceVersion. These permissions are required by the extension controller, and therefore the installer service account must be able to grant them." — same source
- Namespace-scoped Role (upstream): Deployment `verbs: [create]` + `verbs: [get, list, watch, update, patch, delete]` with `resourceNames: [argocd-operator-controller-manager]`; ServiceAccount `verbs: [create, list, watch]` + `[get, update, patch, delete]` scoped by name; Services and ConfigMaps `create` + scoped `get, list, watch, update, patch, delete`. — same source
- "Putting it all together: 1. Create the installation namespace 2. Create the installer ServiceAccount 3. Create the installer ClusterRole 4. Create the ClusterRoleBinding between the installer service account and its cluster role 5. Create the installer Role 6. Create the RoleBinding between the installer service account and its role 7. Create the ClusterExtension" — same source
- Upstream "quick cluster-admin for testing" variant: "The `cluster-admin` ClusterRole can be bound to the installer service account giving it full permissions to the cluster. While this obviates the need to determine the minimal RBAC required for installation, it is also dangerous. It is highly recommended that this alternative only be used in test clusters. Never in production."
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: my-cluster-extension-installer-role-binding
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: cluster-admin
  subjects:
  - kind: ServiceAccount
    name: my-cluster-extension-service-account
    namespace: my-cluster-extension-namespace
  ```
  ```sh
  kubectl create clusterrolebinding my-cluster-extension-installer-role-binding \
    --clusterrole=cluster-admin \
    --serviceaccount=my-cluster-extension-namespace:my-cluster-installer-service-account
  ```
  and "the scripts in hack/tools/catalogs were created to help the user navigate and search catalogs as well as to generate the minimal RBAC requirements. These tools are offered as is, with no guarantees on their correctness, support, or maintenance." — [derive-service-account.md v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/howto/derive-service-account.md); the ArgoCD sample manifest with the "final permission set" is [config/samples/olm_v1_clusterextension.yaml](https://github.com/operator-framework/operator-controller/blob/main/config/samples/olm_v1_clusterextension.yaml)
- Red Hat developer article (June 2, 2025, Tony Wu) uses the cluster-admin shortcut for Quay: SA `quay-installer-sa` in `redhat-quay` bound to `cluster-admin` by ClusterRoleBinding `my-cluster-extension-installer-role-binding`; "OLM v1 operates under a least privilege model and requires a user-provided ServiceAccount with appropriate role-based access control (RBAC) permissions to manage ClusterExtensions." — [developers.redhat.com](https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1)

**Preflight permissions check (reports missing RBAC in status) — Tech Preview on OCP 4.19–4.22; removed upstream in v1.11.0:**
- Red Hat: "Before installing an extension, the Operator Controller performs a dry run to verify service account access. … If the service account is missing any required RBAC rules, the preflight check fails before the actual installation proceeds. If the preflight check fails, the Operator Controller reports the errors in the status conditions of the extension and in the logs of the Operator Controller." Verbatim example report (`$ oc describe clusterextension <extension_name>`):
  ```
  Conditions:
    Type:    Progressing
    Status:  False
    Reason:  Retrying
    Message: pre-authorization failed: service account requires the following permissions to manage cluster extension:
             Namespace:"" APIGroups:[] Resources:[services] Verbs:[list,watch]
             Namespace:"pipelines" APIGroups:["apps"] Resources:[deployments] Verbs:[create]
  ```
  "Common permission errors": "Missing verbs", "Privilege escalation — The service account does not have enough permission to create a role or cluster role that the extension needs. When this happens, the preflight check reports the verbs as missing to prevent privilege escalation.", "Missing role references — … the preflight check lists the missing role and reports an authorization evalutation error." — [OCP 4.20 Extensions guide §5.1.6](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); still §5.2.5 "(Technology Preview)" in [4.22](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- Red Hat release-notes TP tracker rows: "OLM v1 permissions preflight check for cluster extensions — 4.18 Not Available / 4.19 Technology Preview / 4.20 Technology Preview" and "4.20 TP / 4.21 TP / 4.22 TP" — [OCP 4.20 release notes §1.7.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/release_notes/index); [OCP 4.22 release notes §1.9.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/release_notes/index)
- Feature-gate names on the OpenShift fork: `PreflightPermissions`, `SingleOwnNamespaceInstallSupport` (release-4.19); plus `SyntheticPermissions`, `WebhookProviderCertManager`, `WebhookProviderOpenshiftServiceCA`, `HelmChartSupport` (release-4.20); plus `BoxcutterRuntime` (release-4.21); plus `DeploymentConfig` (release-4.22). `PreflightPermissions` and `SyntheticPermissions` are `featuregate.Alpha`, `Default: false` on every branch. — [release-4.22 features.go](https://github.com/openshift/operator-framework-operator-controller/blob/release-4.22/internal/operator-controller/features/features.go) (and release-4.19/4.20/4.21 equivalents)
- What OpenShift's `TechPreviewNoUpgrade` manifest turns on (release-4.21 and release-4.22, identical): `--feature-gates=WebhookProviderOpenshiftServiceCA=true`, `--feature-gates=SingleOwnNamespaceInstallSupport=true`, `--feature-gates=PreflightPermissions=true`, `--feature-gates=WebhookProviderCertManager=false`, `--feature-gates=HelmChartSupport=false`, `--feature-gates=BoxcutterRuntime=false`. `SyntheticPermissions` is not enabled in either manifest; the standard (non-TechPreview) manifest passes no `--feature-gates` flag at all. — [release-4.22 openshift/operator-controller/manifests-experimental.yaml](https://github.com/openshift/operator-framework-operator-controller/blob/release-4.22/openshift/operator-controller/manifests-experimental.yaml), [manifests.yaml](https://github.com/openshift/operator-framework-operator-controller/blob/release-4.22/openshift/operator-controller/manifests.yaml)
- Upstream history of these gates: v1.2.0 "✨ Add feature gate for preflight permissions (#1666)"; v1.3.0 "✨ Check known required permissions for install before installing with the helm applier (#1858)", "🐛 OCPBUGS-55165 Permissions preflight error output fixes (#1934)", "✨ auth: use synthetic user/group when service account is not defined (#1816)"; v1.4.0 "📖 [doc] Initial draft doc preflight perms (#1950)", "🌱 Remove synthetic auth from experimental manifests (#2092)"; v1.8.0 "✨ Add preauthorizer checks to Boxcutter applier (#2443)", "✨ (feat): When using Boxcutter feature-gate, use ClusterExtension ServiceAccount for revision operations (#2429)", "🐛 Replace cluster-admin with least-privilege RBAC for BoxcutterRuntime (#2514)"; v1.9.0 "✨ Add ServiceAccount validation to ClusterExtension reconciliation (#2488)", "✨ Make RBACPreAuthorizer collection verbs configurable (#2539)", "🐛 make create verb a fixed namespaced collection verb for preflight checks (#2587)". — [GitHub releases API](https://github.com/operator-framework/operator-controller/releases)
- An earlier attempt to make the SA optional ("✨ OPRUN-4221: Use operator-controller SA by default, make SA field optional", PR #2333, and follow-up PR #2355 "Sa optional") was closed unmerged in Nov/Dec 2025; its description: "Operator-controller will use its own service account by default unless the spec.ServiceAccount field is set. … RBAC PreAuthorization only happens if the optional SA field is set". — [PR #2333](https://github.com/operator-framework/operator-controller/pull/2333); [PR #2355](https://github.com/operator-framework/operator-controller/pull/2355)

**The July 2026 reversal (upstream v1.11.0+, OpenShift enhancement merged 2026-07-10, not yet in any shipped OCP branch):**
- Release v1.11.0 (2026-07-23): "✨ Deprecate ClusterExtension spec.serviceAccount by @pedjak in #2770" and "⚠ remove HelmChartSupport feature gate and native Helm chart code (#2798)". — [v1.11.0 release](https://github.com/operator-framework/operator-controller/releases/tag/v1.11.0)
- PR #2770 (merged 2026-07-20): rationale "any users granted permission to create ClusterExtension resources are effectively being delegated cluster-admin trust. Requiring administrators to create least-privileged RBAC for ClusterExtension installation does not remove this avenue of privilege escalation."; changes: "Mark field deprecated via godoc and omitzero tag", "Add ValidatingAdmissionPolicy emitting kubectl deprecation warnings when set", "Delete authentication/ and authorization/ packages", "Eliminate PreflightPermissions and SyntheticPermissions feature gates", "Replace per-ClusterExtension cache with shared TrackingCache", ~5,700 lines removed; design doc [openshift/enhancements#2054](https://github.com/openshift/enhancements/pull/2054). — [PR #2770](https://github.com/operator-framework/operator-controller/pull/2770)
- Current `main` API text: "serviceAccount is a deprecated field and is completely ignored. OLMv1 is a single-tenant system where users with ClusterExtension write access are effectively delegated cluster-admin trust. The operator-controller runs with cluster-admin privileges and uses its own service account for all cluster interactions. Deprecated: serviceAccount is no longer used and will be removed in a future release." with `ServiceAccount ServiceAccountReference \`json:"serviceAccount,omitzero"\`` and the name validation relaxed to "name is immutable once set but may be cleared". — [api/v1/clusterextension_types.go (main)](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go); [API reference](https://github.com/operator-framework/operator-controller/blob/main/docs/api-reference/olmv1-api-reference.md)
- `main` feature gates now: `SingleOwnNamespaceInstallSupport` (Alpha, false), `WebhookProviderCertManager` (GA, true), `WebhookProviderOpenshiftServiceCA` (GA, true), `BoxcutterRuntime` (Alpha, false), `DeploymentConfig` (Alpha, false), `BundleReleaseSupport` (Alpha, false). No `PreflightPermissions`/`SyntheticPermissions`. — [features.go (main)](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/features/features.go)
- Enhancement `enhancements/olm/service-account-deprecation.md` (status `implementable`, tracking OCPSTRAT-3040, creation-date 2025-10-08, last-updated 2026-06-19): "Deprecate the spec.serviceAccount field from the ClusterExtension API in the operator-controller and grant the controller cluster-admin privileges." Motivation: "Any ClusterExtension writer can reference any ServiceAccount in any namespace they have access to", "Extension content is inherently cluster-scoped … Kubernetes RBAC cannot restrict create operations by resource name", "Internal implementation details leak into required permissions … the Helm applier's ContentManager requires list/watch on cluster-scoped resources, while the boxcutter applier does not". Telemetry: "only 59 clusters have any ClusterExtension resources, with a total of 80 ClusterExtensions across the fleet." Goals include "Remove the per-ServiceAccount infrastructure (alpha feature gates PreflightPermissions and SyntheticPermissions, impersonation code, per-extension caches)". Non-goal: "Removal of spec.serviceAccount from the API. This proposal covers deprecation only". Upgrade path: "a new ClusterRoleBinding (`operator-controller-cluster-admin-rolebinding`) is created and the old ClusterRoleBinding and custom ClusterRole are cleaned up by `cluster-olm-operator`"; VAP warning text: "spec.serviceAccount is deprecated, ignored, and will be removed in a future release. The operator-controller's cluster-admin service account is used for all cluster interactions." with `validationActions: - Warn`. "Downstream deprecation tracking: … The specific mechanism for blocking upgrades prior to field removal (e.g., Upgradeable=False) will be determined closer to the removal release". "OLMv1 is not currently available in HyperShift environments." — [service-account-deprecation.md](https://github.com/openshift/enhancements/blob/master/enhancements/olm/service-account-deprecation.md)
- Upstream design decisions now say: "The operator-controller uses its own cluster-admin service account for all operations. Because creating or modifying a ClusterExtension triggers cluster-admin-level operations, cluster administrators should treat write access to the ClusterExtension API as equivalent to granting cluster-admin privileges. … pair RBAC with a ValidatingAdmissionPolicy." and "Previously, OLMv1 required cluster administrators to bind ServiceAccounts with associated RBAC … In practice, this did not provide meaningful security". — [docs/project/olmv1_design_decisions.md (main)](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_design_decisions.md)
- Replacement access-control recipe (upstream `main`): "By default, only cluster administrators have permission to read, create, modify, or delete ClusterExtension and ClusterObjectSet resources." Example ClusterRoles `clusterextension-viewer-role` (get/list/watch on `clusterextensions`, `clusterobjectsets`) and `clusterextension-installer-role` (create/update/delete/get/list/watch), and a `ValidatingAdmissionPolicy` `ce-policy-team-monitoring` with `failurePolicy: Fail`, `matchConstraints.resourceRules` on `olm.operatorframework.io/v1 clusterextensions` `CREATE,UPDATE`, `matchConditions` `request.userInfo.groups.exists(g, g == "team-monitoring")`, and validations such as `object.spec.namespace in ["monitoring", "observability"]`, catalog selector `matchLabels["team"] == "monitoring"`, package/version allowlist regexes, `upgradeConstraintPolicy != "SelfCertified"`, and `crdUpgradeSafety.enforcement != "None"`. — [docs/howto/how-to-protect-olmv1-api-access.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-protect-olmv1-api-access.md)

### Inferences
- For an operator author targeting OpenShift today (4.18–4.22), the user-facing install doc must still include a namespace, an installer SA, a ClusterRole/ClusterRoleBinding (and optionally Role/RoleBinding), and the ClusterExtension with `spec.serviceAccount.name`; the least-privilege rule set is mechanically derivable from the bundle and must be re-derived whenever a new bundle version adds CRDs, Deployments, Services, ConfigMaps, cluster-scoped objects or CSV permissions (Red Hat: upgrades halt until the admin grants new permissions).
- Because `create`/`list`/`watch` cannot be name-scoped and the generated ClusterRole/ClusterRoleBinding names (`<packageName>.<hash>`) are unknown before the first install, the practical least-privilege flow is: install with `resourceNames: ["*"]` on the `get/update/patch/delete` rules, then tighten after inspecting the cluster (both Red Hat and upstream say this).
- The same manifests will keep working after an OpenShift release adopts operator-controller ≥ v1.11: the field becomes optional and ignored, a `Warning` header is emitted, and the installer SA/RBAC become dead weight that can be deleted. Authors should plan to ship two variants of the install doc (or a note) keyed on the OCP version. (Inference from the enhancement's "Existing installation with ServiceAccount set" user story and backward-compatibility goal.)
- The OpenShift fork's `main` branch already carries the deprecated-field API, so the first OCP release after 4.22 is the earliest candidate for the cluster-admin model; the enhancement gives no target release ("Timeline to be confirmed in downstream implementation" per the PR summary), so treat this as unconfirmed.
- Mapping OCP branch → upstream version is not stated anywhere; by feature-gate inventory, release-4.20 ≈ upstream v1.4/v1.5 (no `BoxcutterRuntime`), release-4.21 ≈ v1.6–v1.8 (`BoxcutterRuntime`, webhook gates GA), release-4.22 ≈ v1.9/v1.10 (`DeploymentConfig`, no `BundleReleaseSupport`). This is an inference only.

### Gaps
- No Red Hat KCS article on OLM v1 install/RBAC/migration surfaced in searches limited to primary sources; none is cited.
- The Jira OPRUN-3613 (preflight permissions) page could not be fetched (login-gated); facts about the preflight check come from Red Hat docs and upstream release notes instead.
- Whether OpenShift will keep the Tech Preview "preflight permissions check" in 4.23+ is undocumented; upstream has already deleted it.
- The exact operator-controller version embedded in each OCP release is not published in the docs or fork metadata I could reach.

---

## Key question 2: ClusterExtension manifest variants (pin, ranges, channels, both, `upgradeConstraintPolicy`, CRD-upgrade-safety enforcement, `config`/`watchNamespace`) and how to read resolution results in `status`

### Takeaway
`spec.source.catalog` takes `packageName` (required, immutable), optional `version` (exact or semver comparison string ≤ 64 chars; `~`, `^`, `x`/`X`/`*` wildcards, `||`), optional `channels` (array), optional `selector` (catalog label selector), and optional `upgradeConstraintPolicy` (`CatalogProvided` default | `SelfCertified`); `spec.install.preflight.crdUpgradeSafety.enforcement` is `Strict` (default) or `None`; `spec.config.configType: Inline` with `inline.watchNamespace` selects Own/SingleNamespace mode (feature-gated/Tech Preview). Resolution results appear in `status.install.bundle.{name,version}` and in the `Installed`/`Progressing`/`Deprecated` condition family; the installed image is only in the `Installed` condition message.

### Cited Findings

**Field semantics (API reference, upstream `main`):**
- `version`: "version is an optional semver constraint (a specific version or range of versions). When unspecified, the latest version available is installed. Acceptable version ranges are no longer than 64 characters. Version ranges are composed of comma- or space-delimited values and one or more comparison operators, known as comparison strings. You can add additional comparison strings using the OR operator (||)." — [olmv1-api-reference.md](https://github.com/operator-framework/operator-controller/blob/main/docs/api-reference/olmv1-api-reference.md); CRD CEL error on bad syntax: `message="invalid version expression"` — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- `packageName` immutable (`message="packageName is immutable"`), `namespace` immutable (`message="namespace is immutable"`), both DNS-1123 validated; `catalog` "is required when sourceType is Catalog, and forbidden otherwise"; `inline` "is required when configType is Inline, and forbidden otherwise"; `preflight` "at least one of [preflight] are required when install is specified"; `crdUpgradeSafety` "at least one of [crdUpgradeSafety] are required when preflight is specified". — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- `enforcement`: "Allowed values are "None" or "Strict". The default value is "Strict". When set to "None", the CRD Upgrade Safety pre-flight check is skipped during an upgrade operation. Use this option with caution as unintended consequences such as data loss can occur." — [API reference](https://github.com/operator-framework/operator-controller/blob/main/docs/api-reference/olmv1-api-reference.md)
- `progressDeadlineMinutes` (experimental channel only): "defines the maximum period of time in minutes after which an installation should be considered failed and require manual intervention. This functionality is disabled when no value is provided. The minimum period is 10 minutes, and the maximum is 720 minutes (12 hours)." — [API reference](https://github.com/operator-framework/operator-controller/blob/main/docs/api-reference/olmv1-api-reference.md)
- `upgradeConstraintPolicy`: "`SelfCertified`: Does not limit the next version to the set of successors, and instead allows for any downgrade, sidegrade, or upgrade. `CatalogProvided`: Only allows the next version to come from the successors list. This is the default value." — [concepts/upgrade-support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/)

**Version-range syntax (verbatim tables):**
- Basic comparisons: `=` equal (not aliased to an operator), `!=`, `>`, `<`, `>=`, `<=`. Range: `version: ">=3.0, <3.6"`. Wildcards (`x`, `X`, `*`): `1.2.x` ≡ `>= 1.2.0, < 1.3.0`; `>= 1.2.x` ≡ `>= 1.2.0`; `<= 2.x` ≡ `< 3`; `*` ≡ `>= 0.0.0`. Tilde: `~1.2.3` ≡ `>= 1.2.3, < 1.3.0`; `~1` ≡ `>= 1, <2`; `~2.3` ≡ `>= 2.3, < 2.4`; `~1.2.x` ≡ `>= 1.2.0, < 1.3.0`; `~1.x` ≡ `>= 1, < 2`. Caret: `^1.2.3` ≡ `>= 1.2.3, < 2.0.0`; `^1.2.x` ≡ `>= 1.2.0, < 2.0.0`; `^2.3` ≡ `>= 2.3, < 3`; `^2.x` ≡ `>= 2.0.0, < 3`; `^0.2.3` ≡ `>=0.2.3 <0.3.0`; `^0.2` ≡ `>=0.2.0 <0.3.0`; `^0.0.3` ≡ `>=0.0.3 <0.0.4`; `^0.0` ≡ `>=0.0.0 <0.1.0`; `^0` ≡ `>=0.0.0 <1.0.0`. — [docs/concepts/version-ranges.md](https://github.com/operator-framework/operator-controller/blob/main/docs/concepts/version-ranges.md)
- Red Hat: "A comparison string is a list of space- or comma-separated values and one or more comparison operators enclosed in double quotation marks ("). You can add another comparison string by including an OR, or double vertical bar (||), comparison operator between the strings." and examples `1.14.0`, `1.14.x`, `>=1.16`, `">1.15, <1.17"`. — [OCP 4.20 Extensions guide §5.3.2 and §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Upstream install tutorial: "If you use a comparison string to define a version range, the string must be surrounded by double quotes (`"`)." — [tutorials/install-extension](https://operator-framework.github.io/operator-controller/tutorials/install-extension/)

**Manifest variants, verbatim:**
- Pin (disables automatic updates): "To disable automatic updates, and pin the version of an extension, set `version` in the Catalog source to a specific version (e.g. 1.2.3)."
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterExtension
  metadata:
    name: argocd
  spec:
    namespace: argocd
    source:
      sourceType: Catalog
      catalog:
          packageName: argocd-operator
          version: 0.6.0 # Pin argocd-operator to v0.6.0
  ```
  — [docs/howto/how-to-pin-version.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-pin-version.md)
- Range auto-updates: `version: ">=3.0, <3.6"  # Install versions from v3.0.0 up to, but not including, v3.6.0`; "Any new version of the extension released in the catalog within this range will be automatically applied." — [how-to-version-range-upgrades.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-version-range-upgrades.md)
- Z-stream only: `version: "~2.3" # Automatically upgrade patch releases for v2.3` — [how-to-z-stream-upgrades.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-z-stream-upgrades.md)
- Channels: `channels: [dev-preview, preview]` ("Automatically upgrade to the latest version found in the preview and dev-preview channels"); combined: `channels: [stable] # Automatically upgrade to the latest version found in 'stable'` + `version: "!=1.3.2" # Don't allow version 1.3.2`. — [how-to-channel-based-upgrades.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-channel-based-upgrades.md)
- Red Hat semantics: "If you specify a channel in the CR, OLM v1 installs the latest version of the Operator or extension that can be resolved within the specified channel. When updates are published to the specified channel, OLM v1 automatically updates to the latest release that can be resolved from the channel." / "If you specify the Operator or extension's target version in the CR, OLM v1 installs the specified version. When the target version is specified in the CR, OLM v1 does not change the target version when updates are published to the catalog." / "When you specify a version range, OLM v1 installs the latest version of an Operator or extension that can be resolved by the Operator Controller." Example with both: `channels: - latest` and `version: "<1.16"`. — [OCP 4.20 Extensions guide §2.2.1.1 and §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Red Hat canonical install CR (OCP 4.20–4.22):
  ```yaml
  apiVersion: olm.operatorframework.io/v1
    kind: ClusterExtension
    metadata:
      name: <clusterextension_name>
    spec:
      namespace: <installed_namespace>
      serviceAccount:
        name: <service_account_installer_name>
      source:
        sourceType: Catalog
        catalog:
          packageName: <package_name>
          channels:
            - <channel_name>
          version: <version_or_version_range>
          upgradeConstraintPolicy: CatalogProvided
  ```
  "spec.namespace — Specifies the namespace where you want the bundle installed, such as pipelines or my-extension. Extensions are still cluster-scoped and might contain resources that are installed in different namespaces." — [OCP 4.20 Extensions guide §5.1.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Catalog selection: `selector.matchLabels` / `matchExpressions` (operators `In`, `NotIn`, `Exists`, `DoesNotExist`); resolution order "Priority-based selection: Catalogs with higher priority values (default is 0) are preferred", "Non-deprecated bundles take precedence over deprecated alternatives", "If multiple bundles are from catalogs with the same highest priority, and there is still ambiguity, an error is generated." — [concepts/controlling-catalog-selection](https://operator-framework.github.io/operator-controller/concepts/controlling-catalog-selection/). Install-tutorial warning: "If multiple catalogs are added to a cluster, you cannot specify a catalog when you install an extension. OLM 1.0 requires that all of the extensions have unique bundle and package names for dependency resolution. As a result, if two catalogs have an extension with the same name, the installation might fail or lead to an unintended outcome." — [tutorials/install-extension](https://operator-framework.github.io/operator-controller/tutorials/install-extension/)
- CRD upgrade safety off:
  ```yaml
  install:
    preflight:
      crdUpgradeSafety:
        enforcement: None
  ```
  or `kubectl patch clusterextension example-extension --patch '{"spec":{"install":{"preflight":{"crdUpgradeSafety":{"enforcement":"None"}}}}}' --type=merge`. "You cannot disable individual field validators. If you disable the CRD Upgrade Safety preflight check, all field validators are disabled." — [concepts/crd-upgrade-safety](https://operator-framework.github.io/operator-controller/concepts/crd-upgrade-safety/); [tutorials/downgrade-extension](https://operator-framework.github.io/operator-controller/tutorials/downgrade-extension/)
- Single/Own namespace via `config` (upstream; OCP 4.21/4.22 Tech Preview requiring `TechPreviewNoUpgrade`):
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterExtension
  metadata:
    name: <extension_name>
  spec:
    namespace: <installation_namespace>
    config:
      configType: Inline
      inline:
        watchNamespace: <watch_namespace>
  ```
  Requirements table: AllNamespaces-only → field "Not applicable"; OwnNamespace-only → Required, "Must match .spec.namespace field"; SingleNamespace-only → Required, "Must differ from .spec.namespace field"; both Own+Single → Required, may match or differ; AllNamespaces plus Own/Single → Optional. "OLM v1 validates the watchNamespace value based on the install mode support that is declared by the bundle. The installation fails with a validation error if you specify an invalid value or omit a required field." "The MultiNamespace install mode is not supported." — [OCP 4.21 Extensions guide §5.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/extensions/cluster-extensions); upstream matrix and error strings (`required field "watchNamespace" is missing`, `invalid value "X": watchNamespace must be "Y" (the namespace where the operator is installed) because this operator only supports OwnNamespace install mode`, `invalid value "X": watchNamespace must be different from "Y" (the install namespace) because this operator uses SingleNamespace install mode to watch a different namespace`, `unknown field "foo"`) — [docs/draft/howto/configure-bundles.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/configure-bundles.md)
- OCP 4.20 used an annotation instead: `metadata.annotations: olm.operatorframework.io/watch-namespace: <namespace>` ("If the namespace parameter is empty or if the annotation is not present, the extension is deployed using the AllNamespaces install mode. If the namespace parameter is the same value as the installed_namespace … OwnNamespace … different … SingleNamespace"). — [OCP 4.20 Extensions guide §5.1.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Discover install modes: `opm render <bundle_image> -o json | jq 'select(.schema == "olm.bundle") | .properties[] | select(.type == "olm.bundle.object")'` then `echo "<base64_data>" | base64 -d | jq '.spec.installModes'` — [OCP 4.21 §5.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/extensions/cluster-extensions); upstream one-liner `opm render <bundle-image> -o json | jq 'select(.schema == "olm.bundle") | .properties[] | select(.type == "olm.csv") | .value.spec.installModes'` — [configure-bundles.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/configure-bundles.md)
- Upstream gate churn for this feature: v1.6.0 "Promote Single Own Feature Gate AND Config spec in the CR to GA (OPRUN-4098) (#2268)" then "Revert Single/Own Namespace GA promotion (#2292)"; v1.8.0 "✨ Promote Single Own Feature Gate AND Config spec in the CR to GA (#2428)"; v1.9.0 "✨ OPRUN-4514: Move Single Own Namespace support back to alpha (#2568)". `main` has it Alpha/false. — [releases](https://github.com/operator-framework/operator-controller/releases); [features.go](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/features/features.go)
- OCP 4.22 adds `spec.config.inline.deploymentConfig` (Tech Preview) "providing feature parity with Subscription.spec.config in OLM (Classic)". — [OCP 4.22 release notes §1.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/release_notes/index)

**Observing resolution in `status`:**
- Condition types/reasons (upstream `main`): `Installed` (reasons `Succeeded`, `Failed`, `Absent`), `Progressing` (`Succeeded`, `Retrying`, `Blocked`, `RollingOut`, `InvalidConfiguration`, `ProgressDeadlineExceeded`), `Deprecated`/`PackageDeprecated`/`ChannelDeprecated`/`BundleDeprecated` (`Deprecated`, `NotDeprecated`, `DeprecationStatusUnknown`), and experimental `Available` (`ProbesSucceeded`). — [api/v1/common_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/common_types.go)
- "When Installed is True and the Reason is Succeeded, the bundle has been successfully installed. When Installed is False and the Reason is Failed, the bundle has failed to install. … When Progressing is True and the Reason is Succeeded, the ClusterExtension is making progress towards a new state. When Progressing is True and the Reason is Retrying, the ClusterExtension has encountered an error that could be resolved on subsequent reconciliation attempts. When Progressing is False and the Reason is Blocked, the ClusterExtension has encountered an error that requires manual intervention for recovery. When Progressing is True and Reason is RollingOut, the ClusterExtension has one or more ClusterObjectSets in active roll out." — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- `kubectl get` columns: `Installed Bundle` (`.status.install.bundle.name`), `Installed`, `Progressing`. — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- Verbatim successful status (Red Hat 4.20, `oc get clusterextension pipelines-operator -o yaml`): finalizers `olm.operatorframework.io/cleanup-unpack-cache`, `olm.operatorframework.io/cleanup-contentmanager-cache`; conditions `Deprecated`/`PackageDeprecated`/`ChannelDeprecated`/`BundleDeprecated` `status: "False"` `reason: Deprecated`; `Installed` `status: "True"` `reason: Succeeded` `message: Installed bundle registry.redhat.io/openshift-pipelines/pipelines-operator-bundle@sha256:f7b19… successfully`; `Progressing` `status: "True"` `reason: Succeeded` `message: desired state reached`; `status.install.bundle: {name: openshift-pipelines-operator-rh.v1.14.5, version: 1.14.5}`. — [OCP 4.20 Extensions guide §5.1.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Verbatim failure status when the requested version does not exist (`version: 9.x`): `Progressing` `status: "True"` `reason: Retrying` `message: 'error upgrading from currently installed version "1.15.2": no bundles found for package "openshift-pipelines-operator-rh" matching version "9.x"'` while `Installed` stays `True`/`Succeeded` on `1.15.2`. — [OCP 4.20 §5.1.7 Troubleshooting](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Upstream one-liner: `kubectl get clusterextension argocd -o jsonpath-as-json="{.status.install}"` → `[{"bundle": {"name": "argocd-operator.v0.2.1", "version": "0.2.1"}}]`. — [tutorials/upgrade-extension](https://operator-framework.github.io/operator-controller/tutorials/upgrade-extension/)
- Boxcutter-era extra: `status.activeRevisions` "holds a list of currently active (non-archived) ClusterObjectSets, including both installed and rolling out revisions. **Experimental channel**"; Red Hat 4.22: `$ oc get clusterextension <extension_name> -o jsonpath='{.status.activeRevisions}{"\n"}'`. — [API reference](https://github.com/operator-framework/operator-controller/blob/main/docs/api-reference/olmv1-api-reference.md); [OCP 4.22 §5.3.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- Deprecation fix history: v1.8.0 "🐛 Fix deprecation conditions showing install errors and improve condition semantics (#2296)"; v1.9.0 "🐛 OCPBUGS-78092: fix: stale deprecation conditions after ClusterExtension upgrade (#2590)". — [releases](https://github.com/operator-framework/operator-controller/releases)

### Inferences
- The installed bundle *image* is not a structured status field; it must be parsed from the `Installed` condition message (`Installed bundle <image@sha256:…> successfully`) or from the ClusterObjectSet labels/annotations (`olm.operatorframework.io/bundle-reference`) when Boxcutter is on.
- "Pause"/"freeze" of upgrades has no dedicated field; pinning `version` to an exact value is the documented mechanism (Red Hat: "Specifying an Operator's target version pins the Operator's version to the specified release").
- Combining `channels` with a `version` range is the safest GitOps shape: the channel keeps you on the author's supported stream and the range prevents an unwanted major jump.

### Gaps
- No upstream or Red Hat doc states what happens when both `channels` and `version` are set and *no* bundle satisfies both except the already-installed one (presumably no-op); not verified.
- `progressDeadlineMinutes` and `activeRevisions` are experimental-channel only; whether OpenShift exposes them (even under TechPreview) is not documented.

---

## Key question 3: Install and upgrade mechanics — how bundles are applied, conflicts with pre-existing objects, upgrade edges and major-version rules, pinning, failure handling, and inspection commands

### Takeaway
By default operator-controller unpacks the `registry+v1` bundle, renders it and installs it as a Helm release (labels on every object, release metadata stored with the Helm storage driver); when the `BoxcutterRuntime` gate is on it instead creates a `ClusterObjectSet` per revision applied in ordered phases with readiness probes (OCP 4.22 Tech Preview, retention limit 5). Objects may be owned by exactly one ClusterExtension — pre-existing CRDs or other objects not owned by it fail with `… already exists in namespace '…' and cannot be managed by operator-controller`. Upgrade candidates are the catalog's `replaces`/`skips`/`skipRange` successors (highest semver wins) unless `SelfCertified`; major-version upgrades and 0.x minor hops are never automatic. Failures surface as `Progressing=True/Retrying` (retryable) or `Progressing=False/Blocked` (manual), with the previously installed bundle left in place; there is no automatic rollback.

### Cited Findings
- operator-controller responsibilities: "Identifying the appropriate registry+v1 bundle that meets the constraints defined in the ClusterExtension resource … Unpacking and applying bundle manifests"; "Downloads bundle container images from the registry, saves them to the bundle cache, unpacks them, and applies the bundle manifests to the cluster. Handles bundle upgrades by determining which bundle is the correct one to apply." — [docs/project/olmv1_architecture.md](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_architecture.md)
- Helm applier (default runtime): `func (h *Helm) Apply(ctx, contentFS, ext, objectLabels, storageLabels)` with states `StateNeedsInstall` / `StateNeedsUpgrade`, imports `helm.sh/helm/v3/pkg/storage/driver`, sets `install.Labels = storageLabels` / `upgrade.Labels = storageLabels`, and merges `objectLabels` onto every rendered object (`obj.SetLabels(util.MergeMaps(obj.GetLabels(), p.labels))`). — [internal/operator-controller/applier/helm.go (main)](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/applier/helm.go)
- Label keys written by OLM: `olm.operatorframework.io/owner-kind`, `olm.operatorframework.io/owner-name`, `olm.operatorframework.io/package-name`, `olm.operatorframework.io/bundle-name`, `olm.operatorframework.io/bundle-version`, `olm.operatorframework.io/bundle-release`, `olm.operatorframework.io/bundle-reference`; Secret type `olm.operatorframework.io/object-data` for externalized ClusterObjectSet content. — [internal/shared/labels/labels.go](https://github.com/operator-framework/operator-controller/blob/main/internal/shared/labels/labels.go). Admin query: `kubectl get crds -l 'olm.operatorframework.io/owner-kind=ClusterExtension,olm.operatorframework.io/owner-name=<clusterExtensionName>'` — [docs/howto/how-to-grant-api-access.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-grant-api-access.md)
- Boxcutter applier: `ClusterObjectSetRetentionLimit = 5`; when migrating an existing Helm release it builds the first revision with `WithCollisionProtection(ocv1.CollisionProtectionNone) // allow to adopt objects from previous release`, otherwise `CollisionProtectionPrevent`. — [internal/operator-controller/applier/boxcutter.go](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/applier/boxcutter.go). Release notes: v1.6.0 "✨ Implement Boxcutter (#1946)"; v1.7.0 "⚠️ (Boxcutter Runtime) Revision discovery now uses label-based cache lookups, removing Spec.Previous and preventing orphaned revisions on delete (#2315)"; v1.8.0 "🐛 (fix) Fix race condition in Helm to Boxcutter migration during OLM upgrades (#2440)"; v1.9.0 "⚠️ OPRUN-4518: chore(Boxcutter): Rename ClusterExtensionRevision to ClusterObjectSet (#2589)", "🐛 OCPBUGS-77972: fix: aggregate phase errors to handle SSA migration conflicts (#2639)", "🐛 OCPBUGS-78455: fix(boxcutter): detect collision when duplicate package is installed after upgrade (#2578)". — [releases](https://github.com/operator-framework/operator-controller/releases)
- Red Hat 4.22 on ClusterObjectSets (Tech Preview): "ClusterObjectSets deploy cluster extensions through ordered phases, enabling safe upgrades by maintaining both old and new revisions until the new version succeeds." Phases in order: `namespaces`, `policies` (NetworkPolicy, PodDisruptionBudget, PriorityClass), `identity` (ServiceAccount), `configuration` (Secret, ConfigMap), `storage`, `crds`, `roles`, `bindings`, `infrastructure` (Service, Issuer, Certificate), `deploy` (Deployment), `scaling`, `publish` (PrometheusRule, ServiceMonitor, PodMonitor, Ingress, Route, console), `admission` (Validating/MutatingWebhookConfiguration). "The next phase begins only after all objects in the current phase pass their readiness probes." Inspect: `$ oc get clusterobjectsets`, `$ oc get clusterobjectsets -l olm.operatorframework.io/owner-name=<extension_name>`, `$ oc get clusterobjectset <clusterobjectset_name> -o yaml`. — [OCP 4.22 Extensions guide §5.3.6–5.3.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- Single-owner rule and the exact conflict error: "a Kubernetes resource can only be owned by a single ClusterExtension at a time … Operator bundles provide CustomResourceDefinitions (CRDs) … This means a bundle can only be installed once in a cluster. Attempting to install another bundle that provides the same CRDs will result in a failure"; error `CustomResourceDefinition 'logfilemetricexporters.logging.kubernetes.io' already exists in namespace 'kubernetes-logging' and cannot be managed by operator-controller` — "This error message signals that the resource is already being managed by another ClusterExtension and cannot be reassigned or "shared."" — [docs/concepts/single-owner-objects.md](https://github.com/operator-framework/operator-controller/blob/main/docs/concepts/single-owner-objects.md); same text and error in [OCP 4.20 §2.2.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Supported-content limits enforced at install: registry+v1 only; "must support installation via the AllNamespaces install mode" (Single/Own "not recommended … hard limitation of only one instance of a given CRD in the cluster"); "must not declare dependencies using … olm.gvk.required, olm.package.required, olm.constraint"; "must not define APIServices in the ClusterServiceVersion"; "OLM v1 does not support the OperatorConditions API"; "OLM v1 verifies these criteria at install time and will surface violations in the ClusterExtensions's .status.conditions." — [docs/project/olmv1_limitations.md](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_limitations.md); Red Hat 4.20 adds "The extension must not use webhooks. You can install extensions that use webhooks as a Technology Preview feature in OpenShift Container Platform 4.20" and the OperatorConditions workaround "you can pin your extension to a specific version" — [OCP 4.20 §5.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions). Webhooks are GA in 4.21: "With this update, OLM v1 supports Operators that use webhooks for validation, mutation, or conversion." — [OCP 4.21 release notes §1.3.6](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/release_notes/index); 4.22: "The OpenShift Service CA Operator automatically manages webhook certificates … Generates TLS certificates in the namespace where you install the cluster extension. Mounts certificate secrets to the Operator deployment." — [OCP 4.22 §5.1.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- Upgrade edges: "OLM v1 supports legacy OLM semantics by default … including replaces, skips, and skipRange directives … In legacy OLM, the successor closest to the channel head is chosen. In OLM v1, the successor with the highest semantic version (semver) is chosen." Example: with `example.v3.0.0 skips: ["example.v2.0.0"]` and `example.v2.0.0 skipRange: ">=1.0.0 <2.0.0"`, from `1.0.0` "OLM v1 detects the upgrade edge because OLM v1 does not have a concept of a replaces chain. OLM v1 finds all entries that have a replace, skip, or skipRange value that covers the currently installed version." — [concepts/upgrade-support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/)
- Major-version and 0.x rules: "Currently, OLM 1.0 does not support automatic upgrades to the next major version. You must manually verify and perform major version upgrades." "You cannot automatically upgrade from one patch version to another when both major and minor versions are 0. For example, automatic upgrades within the following version range are not allowed: >= 0.0.1 <0.1.0. You cannot automatically upgrade from one minor version to another minor version within the major version zero. For example, no upgrades from 0.1.0 to 0.2.0. However, you can upgrade from patch versions. For example, upgrades are possible in ranges >= 0.1.0 <0.2.0 …" Forcing: "set the .spec.source.catalog.upgradeConstraintPolicy field to SelfCertified … you can change the version to any version available in the catalogs for a given package." Warning: "Failure to test and verify the upgrade might lead to catastrophic consequences such as data loss." — [concepts/upgrade-support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/); Red Hat: "OLM v1 does not support automatic updates to the next major version or rollbacks to an earlier version. If you want to perform a major version update or rollback, you must verify and force the update manually." — [OCP 4.20 §5.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- The `ForceSemverUpgradeConstraints` gate was removed in v1.2.0 ("✨remove ForceSemverUpgradeConstraints feature gate and implementation (#1638)"). — [v1.2.0 release](https://github.com/operator-framework/operator-controller/releases/tag/v1.2.0)
- Upgrade procedure (upstream): change `version` and `kubectl apply -f -`, or `kubectl patch clusterextension argocd --type='merge' -p '{"spec": {"source": {"catalog": {"version": "0.2.1"}}}}'`; note that `kubectl patch`/`kubectl edit` leave the `kubectl.kubernetes.io/last-applied-configuration` annotation showing the old version. Prerequisites: "The target version is compatible with OLM v1", "Any changes to the CustomResourceDefinition in the new version meet compatibility requirements", "You are not attempting to upgrade between minor versions with a major version of zero". — [tutorials/upgrade-extension](https://operator-framework.github.io/operator-controller/tutorials/upgrade-extension/)
- Channel switch / version change on OpenShift: edit the CR (`oc apply -f pipelines-operator.yaml` → `clusterextension.olm.operatorframework.io/pipelines-operator configured`); find channels with `opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.channel" ) | select( .package == "openshift-pipelines-operator-rh") | .name'` (output `"latest"`, `"pipelines-1.14"`, …) and channel entries with `… | select( .name == "<channel_name>" ) | .entries | .[] | .name`. — [OCP 4.20 §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- CRD upgrade safety (preflight on every CRD update): prohibited — scope change, stored-version removal, new required field, field removal, type change, default added/changed/removed, enum added where none/enum value removed, min increased / max decreased, min/max added; allowed — new enum values, required→optional, min decreased / max increased, new CRD version with no changes to existing ones; "In cases where a change to the CRD does not fall into one of the disallowed change categories but is also unable to be properly detected as allowed, the CRD Upgrade Safety preflight check will prevent the upgrade and log an error for an "unknown change."" Verbatim errors: `validating upgrade for CRD "test.example.com" failed: CustomResourceDefinition test.example.com failed upgrade safety validation. "NoScopeChange" validation failed: scope changed from "Namespaced" to "Cluster"`; `… "NoStoredVersionRemoved" validation failed: stored version "v1alpha1" removed`; `… "NoExistingFieldRemoved" validation failed: crd/test.example.com version/v1alpha1 field/^.spec.pollInterval may not be removed`; `… "ChangeValidator" validation failed: version "v1alpha1", field "^": new required fields added: [pollInterval]`. — [docs/concepts/crd-upgrade-safety.md](https://github.com/operator-framework/operator-controller/blob/main/docs/concepts/crd-upgrade-safety.md). Red Hat 4.20 fix: "the preflight CRD safety check does not block updates when there are changes to documentation fields. (OCPBUGS-55051)" — [OCP 4.20 release notes §1.6.9](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/release_notes/index). Upstream moved the checker to `sigs.k8s.io/crdify` in v1.4.0/v1.6.0 and added "CRD upgrade safety fixes and ratcheting (#2123)" in v1.5.0. — [releases](https://github.com/operator-framework/operator-controller/releases)
- Cluster-upgrade gating by installed extensions: CSV annotation `"olm.properties": '[{"type": "olm.maxOpenShiftVersion", "value": "<cluster_version>"}]'`; "If an installed Operator's olm.maxOpenShiftVersion field is set and a cluster administrator attempts to update their cluster to a version that the Operator does not provide a valid update path for, the cluster update fails and the Upgradeable status for the olm cluster Operator is set to False." — [OCP 4.20 §5.3.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Failure handling: there is no documented automatic rollback; the `Progressing` reasons distinguish `Retrying` (transient) from `Blocked` ("requires manual intervention for recovery"), and the `Installed` condition keeps reporting the last successfully installed bundle (see the `9.x` example above). — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go); [OCP 4.20 §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions). v1.8.0 also "🐛 Workload should still resilient when catalog is deleted (#2439)". — [v1.8.0 release](https://github.com/operator-framework/operator-controller/releases/tag/v1.8.0)
- Inspection commands documented: `kubectl describe clusterextensions`, `kubectl get clusterextension <name> -o yaml`, `kubectl get clusterextension <name> -o jsonpath-as-json="{.status.install}"`, `kubectl logs deployment/<operator_deployment> -n <operator_namespace>`, `kubectl get crd | grep <extension_crd>` — [install](https://operator-framework.github.io/operator-controller/tutorials/install-extension/), [downgrade](https://operator-framework.github.io/operator-controller/tutorials/downgrade-extension/) tutorials; `oc describe clusterextension <extension_name>`, `oc get clusterextension <operator_name> -o yaml`, `oc get clusterextensions` — [OCP 4.20 §5.1.4–5.1.8](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions). On OpenShift "OLM v1 is provided by the olm cluster Operator" with CRDs `clusterextension.olm.operatorframework.io` and `clustercatalog.olm.operatorframework.io`; the catalogd namespace `openshift-catalogd` is named in the Extensions guide. — [OCP 4.21 Operators guide §6.33 "Operator Lifecycle Manager (OLM) v1 Operator"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/operators/index); [OCP 4.20 Extensions guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

### Inferences
- "Pre-existing CRD" is the realistic failure for a WAO-style umbrella: if any medik8s CRD already exists (e.g. left behind by an OLM v0 install or a manual `oc apply`), the ClusterExtension will report the `already exists … cannot be managed by operator-controller` error and stay uninstalled; the only remedies are to delete the foreign object or to let OLM v1 own it from the start.
- Because upgrades apply the *new bundle's* full object set under the single-owner rule, an umbrella operator that itself creates child operators' Deployments/CRDs must not let OLM v1 also manage those objects, or the owner check will trip.
- "Stuck Progressing" is diagnosed from the `Progressing` reason/message; nothing in the docs suggests OLM v1 reverts the previous Helm release/ClusterObjectSet on failure, so a failed upgrade leaves the previous revision running (explicitly the design goal of ClusterObjectSets in 4.22).

### Gaps
- Neither upstream docs nor code excerpts I retrieved state the server-side-apply field-manager name used by the Helm or Boxcutter appliers; not verified.
- No primary doc enumerates the operator-controller / catalogd namespace names on OpenShift beyond `openshift-catalogd` (the Extensions guide mentions it once); the `openshift-operator-controller` namespace name suggested in the task could not be confirmed from the fetched docs.
- The precise behaviour when a Helm-installed extension is migrated to Boxcutter on an OLM upgrade is only visible in release-note titles (#2440) and the `CollisionProtectionNone` code comment; no user-facing doc describes it.

---

## Key question 4: Deletion — what happens to CRDs, CRs and operands; finalizers; recommended order; Red Hat "Deleting an extension"

### Takeaway
Deleting the ClusterExtension deletes everything OLM v1 installed from the bundle, including the CRDs (and therefore, by Kubernetes semantics, all custom resources of those kinds); the two finalizers `olm.operatorframework.io/cleanup-unpack-cache` and `olm.operatorframework.io/cleanup-contentmanager-cache` only clean OLM's own caches. The namespace, the installer SA and its RBAC are not removed and must be deleted afterwards by hand. There is no "retain CRDs" option today.

### Cited Findings
- Upstream: "You can uninstall a Kubernetes extension and its associated custom resource definitions (CRD) by deleting the extension's custom resource (CR)." Procedure `kubectl delete clusterextensions <extension_name>` → `clusterextension.olm.operatorframework.io "argocd" deleted`; verify `kubectl get clusterextension.olm.operatorframework.io` → `No resources found`; "Cleanup: Remove the extension namespace (if applicable)." — [tutorials/uninstall-extension](https://operator-framework.github.io/operator-controller/tutorials/uninstall-extension/)
- Getting-started: "To uninstall an extension, delete the ClusterExtension resource. This will trigger the uninstallation process, which will remove all resources created by the extension." and "Extension installation requires the creation of a namespace. Once the extension is uninstalled, the namespace can be removed." (`kubectl delete namespace argocd`). — [docs/getting-started/olmv1_getting_started.md](https://github.com/operator-framework/operator-controller/blob/main/docs/getting-started/olmv1_getting_started.md)
- Red Hat "Deleting an Operator" (4.20 §5.1.8; identical in 4.21 §5.2.7 and 4.22 §5.2.7): "You can delete an Operator and its custom resource definitions (CRDs) by deleting the ClusterExtension custom resource (CR)." `$ oc delete clusterextension <operator_name>` → `clusterextension.olm.operatorframework.io "<operator_name>" deleted`; verify `$ oc get clusterextensions` → `No resources found`; 4.20 additionally lists "Verify that the Operator's system namespace is deleted by running the following command: `$ oc get ns <operator_name>-system`" → `Error from server (NotFound): namespaces "<operator_name>-system" not found`. — [OCP 4.20 Extensions guide §5.1.8](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [OCP 4.22 §5.2.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- Red Hat developer article: deleting a ClusterExtension "will remove all instances of the custom resources and the operator itself, essentially reverting the cluster to its state before operator installation." and "Future releases will provide options to retain CRDs and custom resources post-uninstall." — [developers.redhat.com, 2025-06-02](https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1)
- Finalizer constants: `ClusterExtensionCleanupUnpackCacheFinalizer = "olm.operatorframework.io/cleanup-unpack-cache"`, `ClusterExtensionCleanupContentManagerCacheFinalizer = "olm.operatorframework.io/cleanup-contentmanager-cache"`; finalizers are now patched rather than updated (v1.8.0 "Use Patch instead of Update for finalizer operations (#2328)"); v1.6.0 "🐛 OCPBUGS-62942: Register cleanup-contentmanager-cache finalizer for BoxcutterRun…". — [clusterextension_controller.go](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/controllers/clusterextension_controller.go); [releases](https://github.com/operator-framework/operator-controller/releases)
- Pre-deprecation RBAC implication: the installer SA needed `delete` on CRDs, ClusterRoles, ClusterRoleBindings, Deployments, Services, ConfigMaps, ServiceAccounts (all the `get, update, patch, delete` rules above) — i.e., uninstall is performed with the installer SA's credentials on OCP 4.18–4.22. — [derive-service-account.md v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/howto/derive-service-account.md); [OCP 4.20 §5.1.3.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Boxcutter: revision discovery "preventing orphaned revisions on delete" (v1.7.0, #2315); e2e "skip clusterobjectset cleanup when BoxcutterRuntime is disabled" (v1.9.0, #2662). — [releases](https://github.com/operator-framework/operator-controller/releases)

### Inferences
- Recommended uninstall order for an operator with operands: (1) delete the operator's custom resources first and wait for the operator to finish its own finalizer cleanup, (2) `oc delete clusterextension <name>` (removes Deployment, RBAC, CRDs — remaining CRs are garbage-collected with the CRD, so any CR finalizers that depend on the now-deleted controller can wedge CRD deletion), (3) delete the namespace, (4) on OCP ≤ 4.22 delete the installer SA, ClusterRole and ClusterRoleBinding. Steps 1 and 4 are inferred from Kubernetes semantics and the RBAC facts; only steps 2–3 are documented.
- Because CRDs are deleted on uninstall and there is no retain option, an operator author must warn users that uninstalling via OLM v1 destroys all operand configuration — the opposite of the OLM v0 behaviour where CRDs survive CSV deletion.
- The `<operator_name>-system` namespace check in the Red Hat 4.20 procedure appears to be a documentation artefact (OLM v1 does not create or delete namespaces); the 4.22 version of the same section drops it.

### Gaps
- No primary source documents a CRD-retention or "orphan" option for OLM v1 as of Oct 2026; the developer article only says one is planned.
- Nothing documents what happens if a CR finalizer blocks CRD deletion during ClusterExtension removal (whether the ClusterExtension deletion hangs on its finalizers).

---

## Key question 5: Migration and coexistence — OLM v0 (Classic) → OLM v1 for an operator already installed via a Subscription

### Takeaway
There is no in-place migration path in any Red Hat or upstream document: OLM v1 and OLM (Classic) run side by side on every OCP release since 4.18 (each with its own catalogs: `ClusterCatalog` vs `CatalogSource`), the console's Software Catalog/Installed Operators pages are still OLM Classic-only (OLM v1 catalog UI is Tech Preview in 4.21/4.22 behind an "Enable OLM v1 (Tech Preview)" toggle), and OLM v1's single-owner rule means a ClusterExtension cannot adopt CRDs/objects that an OLM v0 CSV already created. The only migration guidance that exists covers *configuration* mapping (OperatorGroup → `watchNamespace`, `Subscription.spec.config` → `deploymentConfig`).

### Cited Findings
- "Starting in OpenShift Container Platform 4.18, OLM v1 is enabled by default alongside OLM (Classic)." and "In OpenShift Container Platform, OLM v1 is provided by the olm cluster Operator." — [OCP 4.21 Operators guide §6.33](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/operators/index)
- "In OLM v1, ClusterExtension objects are cluster-scoped. This differs from OLM (Classic) where Operators could be either namespace-scoped or cluster-scoped, depending on the configuration of their related Subscription and OperatorGroup objects." — [OCP 4.20 §2.2.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Single ownership blocks adoption: "Bundles that provide a CustomResourceDefinition (CRD) object can only be installed once. … Attempting to install another bundle that provides the same CRD results in failure" with error `CustomResourceDefinition '…' already exists in namespace '…' and cannot be managed by operator-controller`. — [OCP 4.20 §2.2.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [upstream single-owner-objects.md](https://github.com/operator-framework/operator-controller/blob/main/docs/concepts/single-owner-objects.md)
- Upstream design decision: "We will explore the implications of this design on existing OLMv0 registry+v1 bundles as part of the larger v0 to v1 migration design." (future tense; no such design doc exists in the docs tree as of Oct 2026). — [olmv1_design_decisions.md](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_design_decisions.md)
- Owner labels to look for on existing CRDs: `olm.operatorframework.io/owner-kind=ClusterExtension` and `olm.operatorframework.io/owner-name=<clusterExtensionName>`; a CRD without them is not OLM v1-owned. — [how-to-grant-api-access.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-grant-api-access.md); [labels.go](https://github.com/operator-framework/operator-controller/blob/main/internal/shared/labels/labels.go)
- Catalogs: OLM v1 ships its own default catalogs as `ClusterCatalog` objects — `openshift-redhat-operators` (`priority: -100`, `registry.redhat.io/redhat/redhat-operator-index:v4.20`), `openshift-certified-operators` (`-200`), `openshift-redhat-marketplace` (`-300`), `openshift-community-operators` (`-400`), each with `pollIntervalMinutes` — i.e. the same index images OLM Classic consumes via `CatalogSource`. "OLM v1 shifts from a CustomResourceDefinition (CRD)-based catalog management approach to a new RESTful API". — [OCP 4.20 §4.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); [developers.redhat.com](https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1)
- Configuration migration (install modes): "In OLM v0, configuration was split across multiple resources … "Install Modes" … were handled by the OperatorGroup resource, while operand configuration … via the Subscription resource. In OLM v1, these concepts are unified under the ClusterExtension resource." Table: Namespace Scope — OperatorGroup → `watchNamespace`; User Settings — `Subscription.spec.config` → `ClusterExtension.spec.config.inline`; Multi-Tenancy — "Install Modes are treated as bundle configuration. You install the extension once". — [docs/draft/howto/configure-bundles.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/configure-bundles.md) (added by [PR #2380](https://github.com/operator-framework/operator-controller/pull/2380), merged 2026-01-15)
- Configuration migration (deployment overrides), OCP 4.22 §5.3.5.4 "Converting from OLM (Classic)": "Transfer existing Subscription.spec.config settings to the deploymentConfig object. The YAML structure is the same, but some merge behaviors differ from OLM (Classic). Note: volumes and volumeMounts with the same name override existing entries in OLM v1 rather than appending as in OLM (Classic)." Example maps `Subscription.spec.config.nodeSelector/tolerations` to `ClusterExtension.spec.config.inline.deploymentConfig.nodeSelector/tolerations`. — [OCP 4.22 Extensions guide §5.3.5.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions)
- OLM v1 explicitly does not support: multi-tenancy ("OLM v1 does not support multi-tenancy. You cannot install the same extension more than once on a cluster. As a result, the MultiNamespace install mode is not supported."), the `OperatorConditions` API, dependency resolution (`olm.gvk.required`, `olm.package.required`, `olm.constraint`). — [OCP 4.21 §5.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/extensions/cluster-extensions); [OCP 4.20 §5.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); upstream: "OLM v1 will not automatically install a missing dependency when a user requests an operator." — [olmv1_design_decisions.md](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_design_decisions.md)
- Web console state: 4.20 — "documented procedures for OLM v1 are CLI-based only. Alternatively, administrators can create and view related objects in the web console by using normal methods, such as the Import YAML and Search pages. However, the existing Software Catalog and Installed Operators pages do not yet display OLM v1 components." — [OCP 4.20 §5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); 4.21 — "OLM v1 software catalog in the web console (Technology Preview) — With this update, you can preview the OLM v1 software catalog in the web console. Select Ecosystem → Software Catalog → Operators to preview this feature. To see the OLM (Classic) software catalog, click the Enable OLM v1 (Tech Preview) toggle." — [OCP 4.21 release notes §1.3.6](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/release_notes/index); 4.22 — TP tracker row "OLM v1 software catalog: 4.20 Not Available / 4.21 Technology Preview / 4.22 Technology Preview" and the same "CLI-based only" note — [OCP 4.22 release notes §1.9.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/release_notes/index); [OCP 4.22 Extensions guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions). Enhancement: "The OpenShift Console's OLMv1 workflow is a generic CRD YAML editor with schema-driven documentation — there is no custom ClusterExtension form." — [service-account-deprecation.md](https://github.com/openshift/enhancements/blob/master/enhancements/olm/service-account-deprecation.md)
- OLM (Classic) is still actively maintained and has its own release-note section in 4.20 ("1.6.24. Operator Lifecycle Manager (OLM) Classic"); no deprecation/removal statement for OLM Classic appears in the 4.20, 4.21 or 4.22 release notes I parsed. — [OCP 4.20 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/release_notes/index)

### Inferences
- Migration recipe implied by the facts (not documented anywhere as a procedure): back up operand CRs → delete the OLM v0 Subscription and CSV (which in OLM v0 leaves CRDs/CRs in place) → **also delete the CRDs** (or OLM v1 will refuse with the "already exists … cannot be managed" error) → create namespace/SA/RBAC → create the ClusterExtension → restore CRs. Because deleting CRDs deletes the CRs, this is a destructive, downtime-incurring migration for any operator with stateful operands; for the medik8s set (NHC/SNR/SBR/FAR/MDR/NMO) it means all remediation policies/templates must be re-created.
- A ClusterExtension cannot adopt an OLM v0-installed operator even if the bundle is identical, because OLM v1 applies the bundle as a new Helm release/ClusterObjectSet and the pre-existing objects lack its owner labels (`olm.operatorframework.io/owner-kind/owner-name`) and release metadata.
- Both OLMs read the same Red Hat index images, so a package visible in OperatorHub (Classic) is generally also resolvable by OLM v1 via the default `ClusterCatalog`s, subject to OLM v1's content constraints (no dependencies, AllNamespaces support, no APIService).
- Given the console state, the "default" install path for OpenShift customers through 4.22 remains OLM Classic; an operator author should expect most users to keep using Subscriptions until the OLM v1 console flow leaves Tech Preview.

### Gaps
- Red Hat has published no "migrating from OLM (Classic) to OLM v1" procedure or KCS article that I could find; the absence is itself the finding.
- The Red Hat blog "Announcing OLM v1: next-generation Operator Lifecycle Management" could not be fetched (HTTP 404 on the /en/ path in two attempts); the "enabled by default alongside OLM (Classic)" statement is therefore cited from the OCP docs instead.
- No primary source states whether the OLM v1 console UI (TP) can display or manage ClusterExtensions beyond the catalog browse page.

---

## Key question 6: Operational best practices and what the operator author must document

### Takeaway
Red Hat and upstream converge on: one namespace per extension (pre-created), one installer SA per extension with per-extension RBAC (OCP ≤ 4.22), declarative/GitOps management of the ClusterExtension CR, pin or range-bound versions, watch the `Deprecated`/`PackageDeprecated`/`ChannelDeprecated`/`BundleDeprecated` and `Progressing` conditions, keep `upgradeConstraintPolicy: CatalogProvided` and `crdUpgradeSafety: Strict` except for deliberate forced moves, and (post-v1.11 upstream) treat ClusterExtension write access as cluster-admin and gate it with RBAC + ValidatingAdmissionPolicy.

### Cited Findings
- Namespace per extension: upstream prerequisite "An existing namespace in which to install the extension" and `namespace` "must exist"; Red Hat "Create a new namespace for the service account of the extension that you want to install by running `$ oc adm new-project <new_namespace>`". — [install tutorial](https://operator-framework.github.io/operator-controller/tutorials/install-extension/); [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go); [OCP 4.20 §5.1.3.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions). The enhancement notes cluster-admin "enables future UX improvements such as automatic namespace creation on behalf of extensions". — [service-account-deprecation.md](https://github.com/openshift/enhancements/blob/master/enhancements/olm/service-account-deprecation.md)
- One SA per extension: "Cluster administrators can create a service account for each cluster extension." — [OCP 4.20 §5.1.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- GitOps: "Fully declarative model that supports GitOps workflows … Administrators and SREs can use the API to automate processes and define desired states by using GitOps principles." — [OCP 4.20 §1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); upstream "In OLM v1 we will move to GitOps-friendly APIs that allow administrators to rely on their experience with conventional Kubernetes API behavior (declarative, eventually consistent)". — [olmv1_design_decisions.md](https://github.com/operator-framework/operator-controller/blob/main/docs/project/olmv1_design_decisions.md)
- Deprecation monitoring: the four `Deprecated` conditions, with "The value of False in the status field indicates that the reason: Deprecated condition is not deprecated. The value of True … is deprecated." — [OCP 4.20 §5.1.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); on `main` the `Unknown` state exists: "BundleDeprecated is True if the installed bundle is marked deprecated, False if not deprecated, or Unknown if no bundle is installed yet or if catalog data is unavailable." — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- User access to the installed APIs is *not* set up by OLM v1: "OLM v1 does not automatically configure or manage role-based access control (RBAC) for users to interact with the APIs provided by installed packages. Cluster administrators must manage RBAC"; recommended aggregated ClusterRoles with `rbac.authorization.k8s.io/aggregate-to-view: "true"` etc. — [how-to-grant-api-access.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-grant-api-access.md); Red Hat §5.2 "User access to extension resources" mirrors this. — [OCP 4.20](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
- Restricting who may install (post-deprecation upstream): RBAC on `clusterextensions`/`clusterobjectsets` plus VAP constraints on `spec.namespace`, catalog selector labels, `packageName`/`version`, `upgradeConstraintPolicy`, `crdUpgradeSafety.enforcement`. — [how-to-protect-olmv1-api-access.md](https://github.com/operator-framework/operator-controller/blob/main/docs/howto/how-to-protect-olmv1-api-access.md); enhancement: "Neither mechanism is sufficient alone." — [service-account-deprecation.md](https://github.com/openshift/enhancements/blob/master/enhancements/olm/service-account-deprecation.md)
- Network policies in bundles: "With this release, Operator Lifecycle Manager (OLM) v1 allows Operators to include network policy manifests in their resource bundles." — [OCP 4.20 release notes §1.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/release_notes/index)
- Image signature validation: "OLM v1 runtime validation of container images using sigstore signatures — 4.20 TP / 4.21 TP / 4.22 General Availability". — [OCP 4.22 release notes §1.9.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/release_notes/index)
- Cluster-upgrade gate authors can set: `olm.maxOpenShiftVersion` CSV property (see Q3). — [OCP 4.20 §5.3.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)

### Inferences (what the operator author should document for users)
- **Bundle facts needed to derive RBAC (OCP ≤ 4.22):** list of CRD names, Deployment names, bundle ServiceAccount names, Services, ConfigMaps, Secrets, any cluster-scoped objects (ClusterRoles, webhooks, PriorityClasses, NetworkPolicies), and the full `install.spec.permissions`/`clusterPermissions` — ideally shipped as a ready-made `ClusterRole` + `Role` manifest for the installer SA, with the `resourceNames` for generated `<packageName>.<hash>` RBAC left as `"*"` and a note on tightening after first install. (From Q1 facts.)
- **A ClusterExtension sample** with `namespace`, `serviceAccount.name` (harmless after deprecation), `packageName`, the recommended `channels`, and a conservative `version` range such as `"~X.Y"` or `">=X.Y.0 <X+1.0.0"`; plus a pinned variant. (From Q2 facts.)
- **Install-mode declaration** so users know whether `config.inline.watchNamespace` is required/forbidden; AllNamespaces support is required for GA installs on OCP (Own/Single is TP). (From Q2 facts.)
- **Explicit statements** that the operator does not rely on `OperatorConditions`, OLM dependencies (`olm.package.required` etc.), or `APIService`s — all unsupported by OLM v1. (From Q3 facts.)
- **Upgrade policy**: which versions are catalog-provided successors, that major-version upgrades require `SelfCertified` and manual verification, and the CRD compatibility promise (so CRD upgrade safety passes). (From Q3 facts.)
- **Uninstall warning**: deleting the ClusterExtension deletes the CRDs and therefore all CRs. (From Q4 facts.)
- **Coexistence warning**: do not install the same package via OLM Classic and OLM v1; migrating requires full removal including CRDs. (From Q5 facts.)
- For umbrella/meta-operators (like WAO installing six operands): OLM v1 will only ever manage the umbrella's own bundle objects; the umbrella must own and manage the child operators' objects itself and must never ship child CRDs in its bundle if the children are also installable as separate ClusterExtensions, or the single-owner rule will block one of them. (Inference from Q3 single-owner facts.)

### Gaps
- No Red Hat document prescribes an Argo CD/OpenShift GitOps pattern specifically for ClusterExtension (e.g., sync waves or health checks for the `Installed`/`Progressing` conditions); only generic "supports GitOps workflows" statements exist.
- No Red Hat guidance on alerting/metrics for OLM v1 conditions was found in the Extensions guides fetched.

---

## Key question 7: Exact runnable procedure (consolidated from the cited sources)

### Takeaway
The following sequence is assembled only from commands and manifests quoted above; the two branches reflect the version split (installer-SA model on OCP 4.18–4.22 / upstream ≤ v1.10 vs. cluster-admin model on upstream ≥ v1.11).

### Cited Findings (procedure)
1. Confirm the package, channels and versions from the catalog (OpenShift): `opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.channel" ) | select( .package == "<package>") | .name'` and the bundle list with `opm render … | jq -cs '.[] | select( .schema == "olm.bundle" ) | select( .package == "<package>") | {"name":.name, "image":.image}'`. — [OCP 4.20 §5.1.3.3, §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
2. Create the namespace: `oc adm new-project <ns>` (or `kubectl create namespace <ns>` / the Namespace manifest from the upstream upgrade tutorial). — [OCP 4.20 §5.1.3.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [upgrade tutorial](https://operator-framework.github.io/operator-controller/tutorials/upgrade-extension/)
3. **OCP 4.18–4.22 / upstream ≤ v1.10 only:** create `ServiceAccount <extension>-installer`, the installer `ClusterRole` (derived per Q1, or the all-wildcard test ClusterRole), the `ClusterRoleBinding <extension>-installer-binding`, and (optionally) a namespace `Role`/`RoleBinding` for Deployment/SA/Service/ConfigMap management; apply with `oc apply -f …`. — [OCP 4.20 §5.1.3.2–5.1.3.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [derive-service-account.md v1.10.0](https://github.com/operator-framework/operator-controller/blob/v1.10.0/docs/howto/derive-service-account.md)
4. Apply the ClusterExtension (Red Hat example):
   ```yaml
   apiVersion: olm.operatorframework.io/v1
   kind: ClusterExtension
   metadata:
     name: pipelines-operator
   spec:
     namespace: pipelines
     serviceAccount:
       name: pipelines-installer
     source:
       sourceType: Catalog
       catalog:
         packageName: openshift-pipelines-operator-rh
         version: "1.14.x"
   ```
   `$ oc apply -f pipeline-operator.yaml` → `clusterextension.olm.operatorframework.io/pipelines-operator created`. On upstream ≥ v1.11 omit `serviceAccount` (a `Warning` is emitted if present). — [OCP 4.20 §5.1.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [service-account-deprecation.md](https://github.com/openshift/enhancements/blob/master/enhancements/olm/service-account-deprecation.md)
5. Verify: `oc get clusterextension <name> -o yaml` (expect `Installed=True/Succeeded`, `Progressing=True/Succeeded "desired state reached"`, `status.install.bundle.{name,version}`), or `kubectl get clusterextension <name> -o jsonpath-as-json="{.status.install}"`; on a preflight failure (TP) read `Progressing=False/Retrying "pre-authorization failed: service account requires the following permissions …"` and extend the RBAC. — [OCP 4.20 §5.1.4, §5.1.6](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); [upgrade tutorial](https://operator-framework.github.io/operator-controller/tutorials/upgrade-extension/)
6. Upgrade within range: automatic (ranges/channels); manual pin change: `kubectl patch clusterextension <name> --type='merge' -p '{"spec": {"source": {"catalog": {"version": "<new>"}}}}'`; channel switch: edit `spec.source.catalog.channels` and `oc apply`; on OCP ≤ 4.22 first extend the installer RBAC if the new bundle adds objects/permissions ("OLM v1 halts the update process until a cluster administrator grants those permissions"). — [upgrade tutorial](https://operator-framework.github.io/operator-controller/tutorials/upgrade-extension/); [OCP 4.20 §5.1.3, §5.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
7. Major-version upgrade or downgrade: set `upgradeConstraintPolicy: SelfCertified` (`kubectl patch clusterextension <name> --patch '{"spec":{"source": {"catalog":{"upgradeConstraintPolicy":"SelfCertified"}}}}' --type=merge`), for downgrades additionally `crdUpgradeSafety.enforcement: None`, then change `version`; back up first; verify with `kubectl get clusterextension <name> -o yaml`, `kubectl get crd | grep <extension_crd>`, `kubectl logs deployment/<operator_deployment> -n <operator_namespace>`. — [downgrade tutorial](https://operator-framework.github.io/operator-controller/tutorials/downgrade-extension/); [OCP 4.20 §5.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)
8. Uninstall: `oc delete clusterextension <name>` (removes bundle objects including CRDs) → `oc get clusterextensions` → `No resources found` → delete the namespace → (OCP ≤ 4.22) delete the installer SA/ClusterRole/ClusterRoleBinding. — [uninstall tutorial](https://operator-framework.github.io/operator-controller/tutorials/uninstall-extension/); [OCP 4.20 §5.1.8](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions)

### Inferences
- Steps 3 and the RBAC parts of 6 and 8 disappear entirely once an OpenShift release ships operator-controller ≥ v1.11; everything else is unchanged, so a user-facing install doc can be written once with the SA/RBAC block marked "required on OpenShift 4.18–4.22".

### Gaps
- Red Hat has not yet published the OpenShift release that adopts the deprecated-SA model, so the exact OCP version at which step 3 becomes optional is unknown as of 2026-10-10.
