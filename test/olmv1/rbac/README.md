# OLM v1 installer RBAC for the six RHWA operators (experiment inputs)

Everything under `rbac/<key>/` is **generated** by `../gen-installer-rbac.py`. Do not hand-edit;
regenerate instead. These manifests are inputs to the OLM v1 (`ClusterExtension`) install
experiment on OpenShift 4.22. They are deliberately broad in places and are **not** product RBAC.

## Regenerate

```sh
cd /Users/jmatthews/git/jwmatthews/wao_poc
.venv/bin/python test/olmv1/gen-installer-rbac.py            # writes test/olmv1/rbac/<key>/
.venv/bin/python test/olmv1/gen_installer_rbac_test.py -v
```

Inputs (all offline, nothing touches a cluster):

| key | package | pinned version | CSV source | other bundle objects |
|-----|---------|----------------|------------|----------------------|
| nhc | node-healthcheck-operator | 0.12.1 | `evidence/2026-10-02-olmv1-0001/csv-downstream/*.json` (shipped catalog CSV) | `.cache/bundles/nhc/manifests` (upstream bundle) |
| snr | self-node-remediation | 0.13.1 | same | `.cache/bundles/snr/manifests` |
| far | fence-agents-remediation | 0.8.1 | same | `.cache/bundles/far/manifests` |
| mdr | machine-deletion-remediation | 0.7.1 | same | `.cache/bundles/mdr/manifests` |
| nmo | node-maintenance-operator | 5.7.1 | same | `.cache/bundles/nmo/manifests` |
| sbr | storage-based-remediation | 0.3.1 | `.cache/bundles/sbr/manifests/*.clusterserviceversion.yaml` (upstream 0.3.0; same RBAC shape as downstream 0.3.1) | `.cache/bundles/sbr/manifests` |

Install namespace for all six: `openshift-workload-availability`. Catalog: `openshift-redhat-operators`, channel `stable`.

Per operator the generator writes `00-serviceaccount.yaml`, `10-clusterrole.yaml`,
`20-clusterrolebinding.yaml`, `30-clusterextension.yaml` and a `kustomization.yaml`
(`oc apply -k test/olmv1/rbac/<key>` applies them in order; the namespace must already exist).

## How the ClusterRole is built

The structure follows the OpenShift 4.22 procedure *Creating a cluster role for an extension*
(`olmv1-creating-a-cluster-role.adoc`), with a comment line above every rule group naming the
input that produced it:

1. `clusterextensions/finalizers` update, `resourceNames` = the ClusterExtension name.
2. ClusterRoles / ClusterRoleBindings: `create,list,watch` unscoped; `get,update,patch,delete` unscoped (see below).
3. `escalate` (clusterroles, roles) and `bind` (clusterrolebindings, rolebindings).
4. CRDs: `create,list,watch` unscoped; `get,update,patch,delete` scoped to the owned CRD names.
5. The union of every rule in the CSV `install.spec.permissions` and `clusterPermissions`, verbatim, per
   service account, plus the `namespaces get,list,watch` rule OLM v1 appends when it promotes `permissions`
   to ClusterRoles in AllNamespaces mode, plus the rules of every ClusterRole/Role shipped as a plain bundle
   object (the installer must hold what it grants).
6. Deployments scoped to `install.spec.deployments[].name`.
7. ServiceAccounts scoped to the names referenced by permissions/clusterPermissions/deployments and bundle SAs.
8. Services scoped to the webhook Service OLM v1 renders (`<deployment>-service`), the bundle Services, and
   (NHC only) the console-plugin Service.
9. ConfigMaps (scoped when the bundle ships one), Secrets, Roles/RoleBindings, webhook configurations.
10. Any other bundle object kind (none of the six ships one today; SBR has no SCC object, it grants `use`
    on the built-in `privileged` SCC via a ClusterRole).

## What is deliberately broad, and why

| rule group | scope | reason |
|------------|-------|--------|
| ClusterRoles / ClusterRoleBindings `get,update,patch,delete` | unscoped | OLM v1 names them `<csv-name>-<serviceAccount>-<hash>` (`render.DefaultUniqueNameGenerator` hashes the rule set). The docs' `resourceNames: ["*"]` is only a placeholder: Kubernetes RBAC has no wildcard for `resourceNames`, so the literal `"*"` would match nothing. Tighten after the first install with the real names. |
| `escalate` / `bind` | unscoped | same naming problem; the union of granted rules already satisfies the RBAC escalation check, so these are belt-and-braces. |
| Roles / RoleBindings | unscoped | only rendered when a `watchNamespace` is configured (never, for these AllNamespaces-only operators); kept so a later Single/OwnNamespace experiment does not need a regenerate. |
| Validating/MutatingWebhookConfigurations | unscoped | names are generated from `webhookdefinitions[].generateName` (trailing `-` trimmed); the expected names are listed in the comment so this can be tightened. |
| Secrets | unscoped, cluster-wide | no bundle ships a Secret and OLM v1 renders none (serving-cert Secrets are created by service-ca). Present only so the experiment never stalls on a downstream-only object. |
| ConfigMaps (nhc, nmo, sbr) | unscoped `get,update,patch,delete` | those bundles ship no ConfigMap; the catalog CSV cannot show downstream-only bundle objects. |
| all namespace-scoped groups | granted via a ClusterRole, so cluster-wide | the experiment uses one ClusterRole per operator for simplicity; product RBAC would move Deployments/ServiceAccounts/Services/ConfigMaps/Secrets/Roles/RoleBindings into a Role in `openshift-workload-availability`. |
| Services / ConfigMaps `list,watch` | unscoped (docs step 7 scopes them) | the preflight report example in `olmv1-troubleshooting-rbac-errors-with-preflight-check.adoc` asks for cluster-wide `services list,watch`; a name-scoped `list` cannot satisfy that. |

Everything scoped by `resourceNames` is only as good as the name prediction: the first install's
preflight report (`oc describe clusterextension <name>`, condition `Progressing`) is the authority. If
it lists a missing permission, add it to the generator, not to the YAML.

## Known caveats found while generating

- The catalog CSVs for the five downstream operators do not carry non-CSV bundle objects. The upstream
  bundles in `.cache/bundles/` are used as a proxy for Services, ConfigMaps and metrics ClusterRoles. The
  downstream NHC bundle additionally ships the console plugin; its Deployment and ServiceAccount are visible
  in the CSV, and its Service name (`node-healthcheck-node-remediation-console-plugin`) is taken from the
  operator source.
- The SBR bundle's `ClusterRoleBinding/sbr-operator-sbr-agent-rolebinding` hard-codes the subject namespace
  `sbr-operator-system`; OLM v1 only rewrites the namespace of namespaced objects, so that binding will point
  at a ServiceAccount that does not exist in `openshift-workload-availability`. Not an RBAC-shape problem for
  the installer, but expect the agent SA to be unbound until the operator fixes the binding.
- `spec.source.catalog.selector` is not shown in the local 4.22 doc snippets (`olmv1-installing-an-operator.adoc`,
  `olmv1-clusterextension-api.adoc`); it is part of the `olm.operatorframework.io/v1` API and the OCP
  "catalog content resolution" page. Drop the block if a cluster rejects it.
