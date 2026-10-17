# Operand manifests the OADP way: approach and gap analysis

Date: 2026-10-16. Status: proposal, no code changed. Companion to
`EXPLORE_HOW_OADP_UPDATES.md`.

## Summary

OADP ships one operand, the non-admin controller (NAC), with no custom tooling. A Makefile
target copies the NAC's CRDs and `config/rbac/` directory from a local checkout into OADP's
own `config/` tree, and `operator-sdk generate bundle --extra-service-accounts` folds the
copied RBAC into the OADP ClusterServiceVersion (CSV). OLM creates the NAC ServiceAccount and
its roles at install time. OADP never creates RBAC at runtime, so it has no union role and
no RBAC escalation problem. Its reconciler only creates and deletes one Deployment.

The same recipe works for our six operands. A prototype built from the medik8s checkouts at
the pinned tags produced a WAO CSV whose seven operand ServiceAccounts carry exactly the rule
sets we render at runtime today, and a kustomize overlay reproduced our runtime Deployments,
Services and webhook configurations with only image references differing. About 85 lines of
kustomization plus a Makefile target replace the 869 lines of pipeline Python. No data
processing beyond copy, `kustomize build`, a `yq` kind filter and a `sed` is needed.

Three of our requirements are outside what OADP handles, and each has a cheap answer:

1. Admission webhooks and OpenShift service-ca certificates. A shared kustomize component of
   four strategic-merge patches covers all four webhook operands.
2. Six managers in one namespace. One patch narrows the MDR metrics Service selector.
3. Unbound ClusterRoles and a catalog that can carry them. The ConfigMap catalog (D6) accepts
   only CRDs and CSVs; moving the POC catalog to a file-based catalog (FBC) image removes the
   constraint and lets OLM own 20 ClusterRoles WAO creates by hand today.

Recommendation: adopt the OADP structure, let OLM own operand RBAC through the CSV, keep the
Go renderer for Deployments, Services, ConfigMaps and webhooks, and switch the POC catalog
to FBC. Details, evidence and open decisions follow.

## 1. How OADP does it

Source: `~/git/openshift/oadp-operator` at `fa3a813b` (2026-10-13) and
`~/git/migtools/oadp-non-admin` at `924e93b`.

**Copy step.** `make update-non-admin-manifests` (Makefile lines 1152 to 1168) requires
`NON_ADMIN_CONTROLLER_PATH` and does four things:

- copies every file in the NAC `config/crd/bases/` into OADP `config/crd/bases/` and appends
  each to `config/crd/kustomization.yaml` if missing;
- rewrites the `RELATED_IMAGE_NON_ADMIN_CONTROLLER` env value in `config/manager/manager.yaml`
  with one `yq` expression;
- copies every file listed in the NAC `config/rbac/kustomization.yaml`, plus that
  kustomization, into `config/non-admin-controller_rbac/`;
- copies the NAC samples.

Nothing is transformed. The NAC uses unique object names (`non-admin-controller`,
`non-admin-controller-role`), so no name prefixing is needed. The NAC has no webhooks, no
Services and no ConfigMaps. The target is run by hand. There is no drift check and no tag
pin; it copies whatever is checked out.

**Bundle step.** `config/manifests/kustomization.yaml` lists `../non-admin-controller_rbac`
next to `../default`. `make bundle` runs `kustomize build config/manifests | operator-sdk
generate bundle` with
`--extra-service-accounts "velero,non-admin-controller,oadp-vm-file-restore-controller-manager,oadp-kubevirt-datamover-controller-manager"`
(Makefile line 51). The flag matters: operator-sdk folds a Role or ClusterRole into the CSV
only when it is bound to a ServiceAccount that either belongs to a Deployment in the input or
is named in that flag (`initPermissionSet` and `applyRoles` in
`internal/generate/clusterserviceversion/clusterserviceversion_updaters.go`, identical in
v1.35.0 and v1.42.2). Unbound roles become standalone bundle objects. The result in
`bundle/manifests/oadp-operator.clusterserviceversion.yaml` is a `clusterPermissions` entry
per ServiceAccount, including `non-admin-controller` and `velero`, and the NAC's unbound
admin, editor and viewer ClusterRoles as standalone files.

**Runtime step.** `internal/controller/nonadmin_controller.go` (288 lines) builds the NAC
Deployment in Go by hand: labels, one container, image from the `RELATED_IMAGE` env var,
`serviceAccountName: non-admin-controller`. It does not read the NAC `config/manager/`
manifest. When the feature is disabled it deletes the Deployment and nothing else. The
ServiceAccount and RBAC stay for the life of the CSV, which is also what happens to a
standalone OLM install.

## 2. What we do today

- `hack/fetch-bundles.py` (91 lines) pulls the six published bundle images by digest.
- `hack/extract-operand-manifests.py` (371 lines, 256 lines of tests) parses each CSV and
  emits 90 runtime manifests under `internal/operands/manifests/`, the 12 operand CRDs, and
  `config/rbac/operand_union_role.yaml` (891 lines). It rewrites namespaces, adds the
  service-ca certificate volume and annotations, labels pods per component, narrows the MDR
  Service selector, reproduces OLM's `AllNamespaces` copy of namespaced permissions with the
  appended `namespaces` rule, rejects duplicate object names and checks images against
  `release-set.yaml`.
- `hack/check-bundle.py` (76 lines) and `hack/configmap-catalog.py` (38 lines, 37 of tests)
  enforce and build the ConfigMap catalog, which rejects any standalone bundle object.
- The Go renderer (`internal/operands/render.go`) substitutes the namespace placeholder and
  the pinned images, then the reconciler server-side-applies all 90 objects per enabled
  component, including ServiceAccounts, Roles, ClusterRoles and bindings. Creating RBAC at
  runtime is what forces the union role (design brief D7) and the `bind` verb on WAO.

Pipeline Python in scope: 869 lines. The OLM v1 experiment scripts and the cluster test
harness are separate and not addressed here.

## 3. Side by side

| Concern | OADP | wao_poc today | OADP recipe applied to WAO |
| --- | --- | --- | --- |
| Source of operand manifests | local checkout, any commit | published bundle image by digest | local checkout at the tag in `release-set.yaml` via `git archive` |
| CRDs | copy `config/crd/bases` | extracted from bundle | copy `config/crd/bases` (identical content, see 4.4) |
| Operand RBAC | copied into CSV, OLM creates it | rendered by WAO at runtime | copied into CSV, OLM creates it |
| Union role / RBAC escalation | not needed | 891-line union role, `bind` verb | not needed |
| `AllNamespaces` copy of namespaced permissions | OLM does it | reproduced by Python (D7, README deviation 8) | OLM does it |
| Namespace placeholders in RBAC subjects (D9) | OLM resolves | Python rewrites | OLM resolves |
| Operand Deployment | hand-written Go | copied from CSV | `kustomize build` of upstream `config/default`, filtered by kind |
| Webhooks and certificates | none | Python adds volume and annotations | one shared kustomize component |
| Shared-namespace Service selectors (D10) | one operand, none | Python narrows | one patch for MDR |
| Image pinning | `yq` sets `RELATED_IMAGE_*` env, `:latest` upstream | `release-set.yaml` digests, env substitution at runtime | keep; `yq` syncs env from `release-set.yaml` as OADP does |
| Unbound ClusterRoles | standalone bundle objects | rendered by WAO | standalone bundle objects; needs FBC |
| Drift check | none | `--check` mode | `git diff --exit-code` after regenerate |
| Tooling | Make, yq, kustomize, operator-sdk | Python plus the above | Make, yq, kustomize, operator-sdk, sed |

## 4. Prototype evidence

Everything below ran locally against `git archive` exports of each operand's `config/` tree
at the pinned tag (NHC v0.12.0, SNR v0.13.0, SBR v0.3.0, FAR v0.8.0, MDR v0.7.0,
NMO v0.21.0) with kustomize v5.6.0 and operator-sdk v1.42.3. No cluster was touched.

### 4.1 Name collisions

Every operand's `config/rbac/` uses the kubebuilder defaults: ServiceAccount
`controller-manager`, ClusterRole `manager-role`, Role `leader-election-role`. Unlike the
NAC, they collide. Each upstream `config/default/kustomization.yaml` fixes this with a
`namePrefix` (`node-healthcheck-`, `self-node-remediation-`, `sbr-operator-`,
`fence-agents-remediation-`, `machine-deletion-remediation-`, `node-maintenance-operator-`).
Building all six `config/default` trees and comparing (kind, name) pairs found zero
collisions. The per-operand RBAC wrapper therefore needs the upstream prefix, three lines:

```yaml
namePrefix: node-healthcheck-
resources:
- upstream        # verbatim copy of the operand's config/rbac/
```

### 4.2 CSV folding

With six such wrappers added to `config/manifests/kustomization.yaml` and the union role
removed, `operator-sdk generate bundle` without the flag produced a CSV with only WAO's own
ServiceAccount and 71 standalone RBAC files. With
`--extra-service-accounts` naming the seven operand ServiceAccounts
(`node-healthcheck-controller-manager`, `self-node-remediation-controller-manager`,
`sbr-operator-controller-manager`, `sbr-operator-sbr-agent`,
`fence-agents-remediation-controller-manager`,
`machine-deletion-remediation-controller-manager`,
`node-maintenance-operator-controller-manager`) the CSV gained one `clusterPermissions`
entry per ServiceAccount and one `permissions` entry for each of the six managers.

Rule counts match the files WAO renders today exactly:

| ServiceAccount | CSV clusterPermissions rules | today's ClusterRole rules | CSV permissions rules | today's Role rules |
| --- | --- | --- | --- | --- |
| fence-agents-remediation-controller-manager | 10 | 10 | 4 | 4 |
| machine-deletion-remediation-controller-manager | 8 | 8 | 3 | 3 |
| node-healthcheck-controller-manager | 17 | 17 | 3 | 3 |
| node-maintenance-operator-controller-manager | 14 | 14 | 3 | 3 |
| sbr-operator-controller-manager | 17 | 17 | 3 | 3 |
| sbr-operator-sbr-agent | 8 | 8 | n/a | n/a |
| self-node-remediation-controller-manager | 14 | 14 | 2 | 2 |

This is expected: both paths start from the same `config/rbac/` content, one via the
upstream bundle build and one via ours. The SBR agent ServiceAccount with its privileged
SCC ClusterRole folds the same way the velero ServiceAccount does in OADP.

24 standalone objects remained: five metrics Services, six `metrics-reader` ClusterRoles,
four `ext-remediation` aggregation ClusterRoles (SNR, SBR, FAR, MDR) and nine SBR
admin, editor and viewer ClusterRoles. All are kinds OLM supports as bundle objects
(operator-registry `pkg/lib/bundle/supported_resources.go`). Section 6 covers them.

### 4.3 Runtime objects

A five-line overlay per operand over the upstream `config/default`, with
`namespace: __WAO_NAMESPACE__`, piped through `yq` to keep only Deployment, Service,
ConfigMap, ValidatingWebhookConfiguration and MutatingWebhookConfiguration, plus a shared
kustomize component of four strategic-merge patches for the webhook operands, produced:

| Operand | Deployments | Services | ConfigMaps | Validating | Mutating |
| --- | --- | --- | --- | --- | --- |
| NHC | 1 | 2 | 0 | 1 | 0 |
| SNR | 1 | 2 | 1 | 1 | 1 |
| SBR | 1 | 1 | 0 | 0 | 0 |
| FAR | 1 | 2 | 1 | 1 | 1 |
| MDR | 1 | 1 | 1 | 0 | 0 |
| NMO | 1 | 2 | 0 | 1 | 0 |

Diffs against today's rendered files, after removing the component label WAO adds at
runtime anyway:

- NHC Deployment: only `image: controller:latest` versus the pinned tag.
- SNR Deployment: the image and the `SELF_NODE_REMEDIATION_IMAGE` env value `${IMG}`, an
  upstream `envsubst` placeholder. SBR has the same pattern with `${AGENT_IMG}`.
- SNR webhook Service: identical, including the serving-cert annotation.
- SNR ValidatingWebhookConfiguration: identical except an upstream `commonLabels` label and
  the explicit `port: 443` our extractor writes, which is the API default.
- MDR metrics Service: missing the D10 selector narrowing. See section 5.

Deleting the RBAC kinds inside the same kustomize build instead of filtering afterwards
breaks kustomize name references and left `serviceAccountName: controller-manager`
unprefixed. Filter after the build.

Upstream webhook Deployments have no `volumes` list, so a JSON patch `add` to `/volumes/-`
fails. Strategic-merge patches work and merge by name.

### 4.4 CRDs

The twelve `config/crd/bases/*.yaml` files at the pinned tags differ from our
bundle-derived copies only in a leading YAML document separator and, for NHC, an
`app.kubernetes.io/name` label that its bundle build adds through a label transformer. Schemas
are identical. Each
upstream `config/crd/kustomization.yaml` lists only `bases/` plus the conversion webhook
kustomizeconfig, so copying the bases is equivalent to extracting from the bundle, exactly as
in OADP.

## 5. Gaps OADP does not cover, and what closes them

| Gap | Why OADP does not hit it | Cost to close |
| --- | --- | --- |
| Six operands with colliding default names | one operand with unique names | `namePrefix` wrapper per operand, 3 lines each |
| Admission webhooks served by operands WAO creates at runtime, with OpenShift service-ca certificates. OLM wires certificates only for Deployments in the CSV, and ours cannot be there because they default to Disabled | NAC has no webhooks | one shared kustomize component: certificate volume and mount on the Deployment, serving-cert annotation on `*-webhook-service`, inject-cabundle annotation on both webhook kinds; one `sed` for the per-operand secret name |
| SBR ships a `config/webhook/` directory its `config/default` does not include and its bundle does not declare | n/a | build the upstream `config/default`, never `config/webhook` directly; the prototype did this and SBR produced no webhook |
| Shared namespace: the MDR metrics Service selector `control-plane: controller-manager` matches every manager pod, including WAO's own | one operand | 6-line patch in the MDR overlay adding the component label to the selector; the renderer already labels pods |
| Upstream `config/default` patches that are not RBAC: NHC adds an aggregation label to `manager-role`, NMO adds `OPERATOR_NAMESPACE`, SNR adds env vars and ports | NAC has none | building `config/default` applies them; the RBAC wrapper copies `config/rbac` only, and the folded CSV drops role labels in both approaches, matching a standalone OLM install |
| Image pinning by digest from `release-set.yaml` | OADP ships `:latest` upstream and rewrites one env var | keep the renderer's env substitution; add a `yq` loop that writes the seven `RELATED_IMAGE_*` values from `release-set.yaml` into `config/manager/manager.yaml`, the OADP pattern; set the three placeholder images in the overlays (`controller:latest`, `${IMG}`, `${AGENT_IMG}`) to the upstream tag or to an env-name token the renderer resolves |
| Tag pinning of the source checkout | OADP copies the working tree | `git -C $(OPERAND_SRC)/<repo> archive $(tag)` with the tag read from `release-set.yaml` by `yq`; the working tree state of the checkout stops mattering (all six local checkouts are currently ahead of their tags) |
| Drift detection in CI | none | `make operand-manifests && git diff --exit-code` |
| Standalone bundle objects versus the ConfigMap catalog | OADP uses a real catalog | switch the POC catalog to an FBC image (section 6) |
| Disabled components still get a ServiceAccount, RBAC and OLM-owned ClusterRoles at install | same in OADP; NAC RBAC exists whether or not non-admin is enabled | accept; the hard constraint forbids policies, requests, configs and agents at install, not RBAC |
| Foreign-object guard and `managed-by` label on RBAC | n/a | RBAC leaves WAO's ownership; the guard still applies to the 25 runtime objects |

## 6. The RBAC question

**Is a union of all operand RBAC needed?** No, not if OLM creates the operand RBAC. The
union exists only because WAO creates Roles and ClusterRoles at runtime, and Kubernetes
escalation prevention requires the creator to hold every rule it grants. OLM runs as
cluster-admin and has no such limit. Moving the RBAC into the CSV as per-ServiceAccount
`permissions` and `clusterPermissions` entries removes the union role, the `bind` verb, the
RBAC verbs on WAO's own role, and the hand-made `<serviceaccount>-all-namespaces`
ClusterRoles, because OLM's `ensureSingletonRBAC` already copies every CSV-owned Role into a
ClusterRole with the appended `namespaces` get/list/watch rule for an `AllNamespaces`
OperatorGroup, regardless of which ServiceAccount the Role belongs to. That is the behaviour
the README's deviation 8 reproduced by hand after the NMO restart bug.

**Does anything need merging?** No. Each ServiceAccount keeps its own rule set in the CSV.
There is no cross-operand merge, which also means an operand upgrade changes only its own
entry.

**What about the 20 unbound ClusterRoles?** `metrics-reader` (6), `ext-remediation` (4) and
SBR's admin, editor and viewer roles (9) have no binding, so operator-sdk leaves them as
standalone bundle files and OLM creates them at install. Today WAO renders them at runtime,
which is why the union role must also contain their rules. Two choices:

- Let them be bundle objects. Requires a catalog that carries standalone objects, which a
  ConfigMap-backed CatalogSource does not. An FBC image does, and the OLM v1 experiments
  already describe building one on-cluster (`test/olmv1/README.md`). This removes the last
  reason for any union role. Recommended.
- Keep rendering them at runtime. Needs a small union of just those 20 roles' rules on WAO.
  Keeps the ConfigMap catalog. Not recommended; it keeps the mechanism we want gone.

The `ext-remediation` roles are aggregation roles (label
`rbac.ext-remediation/aggregate-to-ext-remediation`) that NHC uses to reach each remediator's
CRs. They must exist cluster-wide; either choice creates them.

**OLM v1 note.** OLM v1's installer ServiceAccount must hold every permission in the bundle
on OpenShift 4.22, so the union question moves to the installer there. `test/olmv1/gen-installer-rbac.py`
already unions CSV `permissions` and `clusterPermissions` and standalone objects, so the CSV
change needs no new mechanism, only regenerated installer RBAC. On 5.0.0-ec.5 the installer
identity is ignored and the question disappears.

## 7. Make or code?

The data processing today falls into three groups:

| Group | Today | Under the OADP recipe |
| --- | --- | --- |
| Fetch and parse bundle images, read CSV `permissions`, `webhookdefinitions`, `deployments` | Python | gone; `git archive` and `kustomize build` of upstream trees |
| RBAC transforms: namespace rewrite, `AllNamespaces` copy, union role, duplicate detection | Python | gone; OLM and operator-sdk do all of it |
| WAO-specific runtime transforms: namespace placeholder, certificate wiring, component label, MDR selector, images | Python at build time, Go at runtime | kustomize `namespace:` and 5 declarative patches at build time; Go keeps namespace and image substitution it already does |

Nothing that remains is conditional or iterative over parsed structure. It is copy, build,
filter and substitute. Make with kustomize, yq and sed is sufficient, and the prototype glue
totals 85 lines of YAML. The Go that stays is already in the repository.

Hand-writing the six Deployments in Go as OADP does is not recommended. The NAC Deployment
is one container with four env vars. Ours carry affinity, tolerations, topology spread,
probes, security contexts and operand-specific env vars. Copying them preserves upstream
behaviour and is the stated goal of "consume the upstream images exactly".

## 8. Proposed layout

```
release-set.yaml                       unchanged: versions, bundle digests, image digests
operands/                              new, replaces hack/*.py
  nhc/kustomization.yaml               runtime overlay: namespace placeholder, upstream default, images
  nhc/rbac/kustomization.yaml          namePrefix wrapper
  nhc/rbac/upstream/                   verbatim copy of config/rbac at the tag
  ... snr sbr far mdr nmo
  webhook-component/kustomization.yaml shared service-ca patches
  mdr/service-selector-patch.yaml      D10
config/crd/bases/<group>_<kind>.yaml   copied from each operand's config/crd/bases
config/manifests/kustomization.yaml    adds ../../operands/<k>/rbac for the six operands
config/manager/manager.yaml            RELATED_IMAGE_* written by yq from release-set.yaml
config/rbac/operand_union_role.yaml    deleted
internal/operands/manifests/<k>/       generated runtime objects, filtered by kind
```

Makefile sketch:

```make
OPERAND_SRC ?= $(HOME)/git/medik8s
OPERANDS = nhc snr sbr far mdr nmo
EXTRA_SAS = node-healthcheck-controller-manager,self-node-remediation-controller-manager,...

operand-manifests: yq kustomize
	for k in $(OPERANDS); do \
	  repo=$$($(YQ) ".components.$$k.repo" release-set.yaml); tag=$$($(YQ) ".components.$$k.version" release-set.yaml); \
	  rm -rf operands/$$k/upstream && mkdir -p operands/$$k/upstream; \
	  git -C $(OPERAND_SRC)/$$repo archive $$tag config | tar -x -C operands/$$k/upstream; \
	  cp operands/$$k/upstream/config/crd/bases/*.yaml config/crd/bases/; \
	  $(KUSTOMIZE) build operands/$$k | $(YQ) 'select(.kind == "Deployment" or .kind == "Service" or .kind == "ConfigMap" or .kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")' \
	    > internal/operands/manifests/$$k/objects.yaml; \
	done
	for env in $$($(YQ) '.components[].images | keys | .[]' release-set.yaml); do \
	  img=$$($(YQ) ".components[].images.$$env.pinned // \"\"" release-set.yaml | grep .); \
	  $(YQ) -i "(select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$$env\") | .value) = \"$$img\"" config/manager/manager.yaml; \
	done

bundle: ... generate bundle --extra-service-accounts $(EXTRA_SAS) ...
operand-manifests-check: operand-manifests
	git diff --exit-code -- operands config/crd/bases config/manager internal/operands
```

The `upstream/` export can be committed, as OADP commits its copies, or kept out of git and
regenerated. Committing it gives reviewable diffs on operand bumps and is the OADP choice.
`release-set.yaml` needs a `repo:` field per component naming the checkout directory.

Go changes: `embed.go` loads one multi-document file per component instead of ninety files;
`render.go` keeps namespace and image substitution and the component label; `kindOrder`
loses the RBAC kinds; the reconciler stops applying RBAC and loses the RBAC kubebuilder
markers; `components/*.go` drops `Original` if the overlays emit env-name tokens. The
reconciler's foreign-object guard, disable path and retained-resource reporting are
unchanged.

Removed: `hack/fetch-bundles.py`, `hack/extract-operand-manifests.py` and its test,
`hack/check-bundle.py`, `hack/configmap-catalog.py` and its test, `.cache/bundles`,
`provenance.json`, `operand_union_role.yaml`, the `make bundles` target and the
`make test-offline` Python invocation. `check-bundle.py`'s assertions reduce to
`operator-sdk bundle validate` plus two `yq` checks (owned CRD count, env values match
`release-set.yaml`).

## 9. Trade-offs and open decisions

1. **Bundle source changes from image to source tree.** Today the pipeline proves the
   manifests came from the published bundle digest. Under the recipe they come from the git
   tag that the published bundle was built from. The two are equivalent only if upstream
   released from the tag; `release-set.yaml` keeps the bundle digest for reference and a
   one-time comparison (section 4) shows they match for these six releases. The hard
   constraint about consuming images by digest is unaffected: images stay pinned.
2. **Catalog.** FBC replaces the ConfigMap catalog (D6 revisited). Needs an image build and
   push, which the OLM v1 work already does on-cluster. Until then, the 20 unbound
   ClusterRoles and five metrics Services must be either excluded from the RBAC wrappers with
   `$patch: delete` and kept at runtime, or the ConfigMap generator must learn to carry them,
   which it structurally cannot.
3. **Metrics Services appear twice.** The medik8s repos put `metrics_service.yaml` in
   `config/rbac/`, so a verbatim copy puts them in the bundle while the runtime overlay also
   emits them. Delete them in the RBAC wrapper so Services stay runtime-owned and absent for
   Disabled components. Four lines.
4. **RBAC lifecycle.** Operand RBAC now lives and dies with the CSV, not with
   `WorkloadAvailabilityConfig`. Disabling a component leaves its ServiceAccount and roles in
   place. This matches OADP and a standalone OLM install, and it simplifies uninstall, but
   `ensureDisabled` and the `DisableIncomplete` reporting should stop listing RBAC.
5. **operator-sdk warnings.** External CRDs without Go types trigger "provided API should
   have an example annotation" warnings. Harmless; OADP has the same.
6. **`--extra-service-accounts` is a hidden coupling.** A new operand ServiceAccount that is
   not added to the flag silently becomes 71 standalone files. A `yq` assertion that the CSV
   has eight `clusterPermissions` entries guards it.

## 10. Verification plan

Offline, before any cluster:

1. `make operand-manifests bundle` and confirm the CSV has eight `clusterPermissions`
   entries and six operand `permissions` entries, and no `operand-union-role`.
2. `yq` the rules out of each CSV entry and diff them against the current committed
   `10-ClusterRole-*` and `20-Role-*` files. Expect no difference.
3. Diff the new runtime objects against the current `internal/operands/manifests/` after
   normalising the image fields. Expect only the differences listed in section 4.3.
4. `go test ./...` with the renderer loading the new layout.

On the disposable cluster (`jmatthews-422-rhwa.kubeconfig`, authorised in the exploration
brief for deleting CRDs and the prior WAO install; pass the kubeconfig explicitly):

5. Remove the prior WAO install and CRDs, install from the new catalog, confirm the six
   ServiceAccounts and OLM-generated ClusterRoles exist and that no Deployment, Service or
   webhook configuration exists for any operand.
6. Enable NHC and SNR, confirm `Available`, admission CA bundles injected, and no RBAC
   errors in WAO logs. Server-side dry-run a `NodeHealthCheck` and a
   `SelfNodeRemediationTemplate` to prove admission. Never create real policies or
   remediation requests.
7. Enable NMO and watch for 10 minutes to confirm the restart bug from README deviation 8
   does not return, since OLM now owns the `namespaces` rule.
8. Disable all and confirm the 25 runtime objects are deleted and RBAC remains.

## References

- OADP Makefile `update-non-admin-manifests` (lines 1152 to 1168) and `BUNDLE_GEN_FLAGS` (line 51)
- OADP `config/manifests/kustomization.yaml`, `internal/controller/nonadmin_controller.go`
- operator-sdk `internal/generate/clusterserviceversion/clusterserviceversion_updaters.go`, `initPermissionSet`, `applyRoles`
- OLM `pkg/controller/operators/olm/operatorgroup.go`, `ensureSingletonRBAC`
- operator-registry `pkg/lib/bundle/supported_resources.go`
- `docs/archive/bootstrap/design-brief.md` D6, D7, D9, D10; `README.md` deviations 2, 3 and 8
- Prototype inputs: `git archive` of each medik8s repository at its `release-set.yaml` tag
