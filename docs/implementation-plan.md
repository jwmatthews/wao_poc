# Workload Availability Operator (WAO) POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status: plan only. Nothing here has been implemented or run.

**Goal:** Build a proof-of-concept Workload Availability Operator (WAO). Its single OLM bundle owns the twelve CRDs of the six upstream medik8s operators (NHC, SNR, SBR, FAR, MDR and NMO) plus a new cluster-scoped `WorkloadAvailabilityConfig`. Its lifecycle controller installs the six unchanged upstream controller-managers as separate operands when an administrator enables them. The install case must then be verifiable on a live OpenShift cluster.

**Architecture:** One OLM package and CSV deploy only the WAO controller and own thirteen CRDs. The controller reconciles the singleton `WorkloadAvailabilityConfig` named `cluster`. For each enabled component it server-side-applies the exact Deployment, RBAC, Service, ConfigMap and webhook objects extracted from that component's published upstream bundle. Images are pinned by digest from `release-set.yaml`, and objects go into the WAO install namespace. NHC, SNR, FAR and NMO serve admission with OpenShift service-ca certificates (design brief D1). Because all six operands share one namespace, extraction labels every operand pod with its component and narrows any Service selector that would match another component's pods (D10).

**Tech Stack:** Go and controller-runtime in a kubebuilder v4 layout via operator-sdk; envtest; Python 3.11+ with PyYAML for bundle fetching and manifest extraction; podman (or docker) for the operator image; classic OLM on OpenShift 4.x; a ConfigMap-backed `CatalogSource` for the POC.

**Spec:** [design-brief.md](design-brief.md). Operand facts: [operands.md](operands.md). Agent rules: [../AGENTS.md](../AGENTS.md).

## Global Constraints

Every task inherits these.

- Go module path `github.com/jwmatthews/wao_poc`; the operator module lives at the repository root.
- API group `workloadavailability.medik8s.io`, version `v1alpha1`, kind `WorkloadAvailabilityConfig`, cluster-scoped, singleton name `cluster`.
- Component executables are consumed unchanged, by digest, exactly as listed in `release-set.yaml`. Never edit, fork or rebuild a component.
- One package, one CSV, `AllNamespaces` install mode only, install namespace `openshift-workload-availability`.
- Every component defaults to `Disabled`. Installing WAO creates no NHC policy, remediation request, native config or node agent.
- Component CRDs and the WA config CRD are owned by the WAO CSV regardless of enablement.
- WAO owns component manager Deployments, Services, ServiceAccounts, RBAC and webhook configurations; it never reconciles the OLM-owned WAO Deployment.
- Keep each component's own selectors, service accounts and RBAC verbatim. Never merge component RBAC into shared operand roles.
- Never set owner references on administrator objects (policies, templates, configs, Secrets). Never adopt an object WAO did not create.
- Never change a webhook `failurePolicy`.
- No public API field overrides an image.
- Bundle inputs come only from `hack/fetch-bundles.py` into the git-ignored `.cache/bundles/`. Generated outputs are committed.
- Cluster commands always pass `--kubeconfig "$KUBECONFIG"` explicitly. Raw cluster output goes only to the git-ignored `evidence/`. No Secret values are ever captured.

---

## 1. Scope and decisions

### In scope

1. WAO Go operator, API, controller, embedded operand manifests, unit and envtest coverage, bundle and CSV, POC catalog, operator image.
2. Clean-install verification on a live OpenShift cluster. It covers WAO install, all components Disabled, enabling each of the six components, operand parity with the upstream bundles, shared-namespace selector isolation, restart and drift behavior, manager-level disable, config deletion and uninstall.

### Out of scope

- Upgrades, `OperatorCondition` gating and rollout plans. These come in the next plan; keep the bundle layout FBC-compatible.
- Migration from standalone installations, component changes, and real remediation, fencing, Machine deletion, node drain, reboot or storage tests.

### Decisions

The ten POC decisions D1–D10 and their reasons are in [design-brief.md section 8](design-brief.md#8-poc-decisions). Tasks reference them by number.

### Operand facts

[operands.md](operands.md) lists every Deployment, Service, RBAC object, webhook and runtime-created object per component. The extraction script in Task 3 reproduces them from the bundles; tests in Tasks 3–5 assert the specific names used below.

## 2. File structure

```
.                                      # Go module github.com/jwmatthews/wao_poc
  PROJECT, Makefile, Dockerfile, go.mod, README.md, AGENTS.md, release-set.yaml
  cmd/main.go                          # manager wiring, image env validation, default config bootstrap
  api/v1alpha1/
    groupversion_info.go
    workloadavailabilityconfig_types.go
    workloadavailabilityconfig_types_test.go
    zz_generated.deepcopy.go
  internal/images/images.go, images_test.go            # RELATED_IMAGE_* env parsing
  internal/components/component.go, nhc.go, snr.go, sbr.go, far.go, mdr.go, nmo.go, components_test.go
  internal/operands/
    manifests/<nhc|snr|sbr|far|mdr|nmo>/*.yaml  # generated by hack/extract-operand-manifests.py (committed)
    manifests/provenance.json          # bundle refs + sha256 of every input and output file
    embed.go, render.go, render_test.go
  internal/controller/
    workloadavailabilityconfig_controller.go, workloadavailabilityconfig_controller_test.go
    status.go, status_test.go, bootstrap.go, bootstrap_test.go, suite_test.go
  config/
    crd/bases/                         # WA config CRD (controller-gen) + 12 extracted component CRDs
    rbac/role.yaml                     # controller-gen
    rbac/operand_union_role.yaml       # extracted (D7)
    manager/manager.yaml               # RELATED_IMAGE_* env from release-set.yaml
    default/kustomization.yaml
    manifests/bases/workload-availability-operator.clusterserviceversion.yaml
    samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml
  bundle/, bundle.Dockerfile           # make bundle output (committed)
  hack/
    requirements.txt
    fetch-bundles.py                   # pinned bundles -> .cache/bundles (exists already)
    extract-operand-manifests.py, extract_operand_manifests_test.py
    check-bundle.py
    configmap-catalog.py, configmap_catalog_test.py
  test/cluster/
    env.sh, lib.sh, README.md
    00-preflight.sh ... 21-uninstall.sh
    parity.py
  docs/design-brief.md, docs/operands.md, docs/implementation-plan.md
  .cache/  evidence/  dist/  .venv/   # git-ignored
```

---

## 3. Tasks

Commit after every task with a `wao:` prefix. From Task 1 onward run `make test` before committing. Use one Python environment for all helper scripts:

```sh
python3 -m venv .venv && .venv/bin/pip install -r hack/requirements.txt
```

### Task 1: Scaffold the operator module

**Files:**
- Create: `PROJECT`, `Makefile`, `Dockerfile`, `go.mod`, `cmd/main.go`, `api/v1alpha1/*`, `internal/controller/*`, `config/**` (all generated)
- Modify: `.gitignore`, `README.md`

**Interfaces:**
- Produces: Go module `github.com/jwmatthews/wao_poc`; API group `workloadavailability.medik8s.io/v1alpha1`; kind `WorkloadAvailabilityConfig` (cluster-scoped, short name `wac`); Make targets `generate manifests build test docker-build docker-push bundle`.

- [ ] **Step 1: Install the toolchain and record versions**

```sh
# macOS example; use your platform's package manager otherwise
brew install operator-sdk
operator-sdk version
go version
podman --version || docker --version
```

Record the versions in `README.md` under a "Toolchain" heading. Use operator-sdk v1.42 or later.

- [ ] **Step 2: Initialize the project in the repository root**

operator-sdk refuses to initialize a non-empty directory unless the existing files are known. Move the existing files aside, initialize, then restore them:

```sh
mkdir -p /tmp/wao-keep && mv README.md AGENTS.md LICENSE release-set.yaml docs hack /tmp/wao-keep/
operator-sdk init --domain medik8s.io --repo github.com/jwmatthews/wao_poc --project-name workload-availability-operator
operator-sdk create api --group workloadavailability --version v1alpha1 --kind WorkloadAvailabilityConfig --resource --controller
mv /tmp/wao-keep/* . && rmdir /tmp/wao-keep
```

Then make these edits:
- In `api/v1alpha1/workloadavailabilityconfig_types.go`, add `// +kubebuilder:resource:scope=Cluster,shortName=wac` directly above `type WorkloadAvailabilityConfig struct`.
- In `PROJECT`, set `namespaced: false` for the resource.
- Append these lines to `.gitignore`:

```
.venv/
.cache/
evidence/
dist/
bin/
kubeconfig*
*.kubeconfig
```

- [ ] **Step 3: Verify the scaffold builds and the empty test suite passes**

```sh
make generate manifests build test
```

Expected: `config/crd/bases/workloadavailability.medik8s.io_workloadavailabilityconfigs.yaml` contains `scope: Cluster`. `go test` passes; the Makefile downloads envtest binaries.

- [ ] **Step 4: Commit**

```sh
git add -A && git commit -m "wao: scaffold WorkloadAvailabilityOperator POC module"
```

### Task 2: WorkloadAvailabilityConfig API

**Files:**
- Modify: `api/v1alpha1/workloadavailabilityconfig_types.go`
- Create: `api/v1alpha1/workloadavailabilityconfig_types_test.go`
- Modify: `config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml`

**Interfaces:**
- Produces: `ComponentState` (`Enabled`/`Disabled`), component key constants
  `ComponentKeyNodeHealthCheck = "nodeHealthCheck"`, `ComponentKeySelfNodeRemediation = "selfNodeRemediation"`,
  `ComponentKeyStorageBasedRemediation = "storageBasedRemediation"`, `ComponentKeyNodeMaintenance`,
  `ComponentKeyFenceAgentsRemediation`, `ComponentKeyMachineDeletionRemediation`;
  `func (s *WorkloadAvailabilityConfigSpec) StateOf(key string) ComponentState`;
  status types `ComponentStatus`, `DeploymentStatus`, `ImageReference`; condition
  type constants `ConditionAvailable`, `ConditionProgressing`, `ConditionDegraded`;
  `ComponentPhase` constants `Disabled|Progressing|Available|Degraded|DisableIncomplete`;
  `const SingletonName = "cluster"`.

- [ ] **Step 1: Write the failing unit test**

```go
// api/v1alpha1/workloadavailabilityconfig_types_test.go
package v1alpha1

import "testing"

func TestStateOfDefaultsToDisabled(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	for _, key := range AllComponentKeys {
		if got := spec.StateOf(key); got != ComponentStateDisabled {
			t.Fatalf("StateOf(%q) = %q, want Disabled", key, got)
		}
	}
}

func TestStateOfReturnsConfiguredState(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	spec.Components.SelfNodeRemediation.State = ComponentStateEnabled
	if got := spec.StateOf(ComponentKeySelfNodeRemediation); got != ComponentStateEnabled {
		t.Fatalf("got %q, want Enabled", got)
	}
	if got := spec.StateOf(ComponentKeyNodeHealthCheck); got != ComponentStateDisabled {
		t.Fatalf("got %q, want Disabled", got)
	}
}

func TestStateOfUnknownKeyIsDisabled(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	if got := spec.StateOf("bogus"); got != ComponentStateDisabled {
		t.Fatalf("got %q, want Disabled", got)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./api/... -run TestStateOf -v`
Expected: compile failure, `undefined: AllComponentKeys`, `StateOf`.

- [ ] **Step 3: Write the API types**

Replace the generated spec/status in `workloadavailabilityconfig_types.go` with:

```go
// ComponentState is the administrator's intent for one component.
// +kubebuilder:validation:Enum=Enabled;Disabled
type ComponentState string

const (
	ComponentStateEnabled  ComponentState = "Enabled"
	ComponentStateDisabled ComponentState = "Disabled"
)

const (
	ComponentKeyNodeHealthCheck            = "nodeHealthCheck"
	ComponentKeySelfNodeRemediation        = "selfNodeRemediation"
	ComponentKeyStorageBasedRemediation    = "storageBasedRemediation"
	ComponentKeyNodeMaintenance            = "nodeMaintenance"
	ComponentKeyFenceAgentsRemediation     = "fenceAgentsRemediation"
	ComponentKeyMachineDeletionRemediation = "machineDeletionRemediation"

	// SingletonName is the only permitted WorkloadAvailabilityConfig name.
	SingletonName = "cluster"
)

// AllComponentKeys lists every component key the API accepts, in display order.
var AllComponentKeys = []string{
	ComponentKeyNodeHealthCheck, ComponentKeySelfNodeRemediation, ComponentKeyStorageBasedRemediation,
	ComponentKeyNodeMaintenance, ComponentKeyFenceAgentsRemediation, ComponentKeyMachineDeletionRemediation,
}

// ComponentSpec configures one component.
type ComponentSpec struct {
	// state requests the component to be installed (Enabled) or removed at the
	// manager level (Disabled). Unset means Disabled.
	// +kubebuilder:default=Disabled
	// +optional
	State ComponentState `json:"state,omitempty"`
}

// ComponentsSpec holds per-component intent. Every component defaults to Disabled.
type ComponentsSpec struct {
	// +optional
	NodeHealthCheck ComponentSpec `json:"nodeHealthCheck,omitempty"`
	// +optional
	SelfNodeRemediation ComponentSpec `json:"selfNodeRemediation,omitempty"`
	// +optional
	StorageBasedRemediation ComponentSpec `json:"storageBasedRemediation,omitempty"`
	// +optional
	NodeMaintenance ComponentSpec `json:"nodeMaintenance,omitempty"`
	// +optional
	FenceAgentsRemediation ComponentSpec `json:"fenceAgentsRemediation,omitempty"`
	// +optional
	MachineDeletionRemediation ComponentSpec `json:"machineDeletionRemediation,omitempty"`
}

// WorkloadAvailabilityConfigSpec defines the desired state of the installation.
type WorkloadAvailabilityConfigSpec struct {
	// +optional
	Components ComponentsSpec `json:"components,omitempty"`
}

// StateOf returns the effective state for a component key; unknown keys and
// unset entries are Disabled.
func (s *WorkloadAvailabilityConfigSpec) StateOf(key string) ComponentState {
	var c ComponentSpec
	switch key {
	case ComponentKeyNodeHealthCheck:
		c = s.Components.NodeHealthCheck
	case ComponentKeySelfNodeRemediation:
		c = s.Components.SelfNodeRemediation
	case ComponentKeyStorageBasedRemediation:
		c = s.Components.StorageBasedRemediation
	case ComponentKeyNodeMaintenance:
		c = s.Components.NodeMaintenance
	case ComponentKeyFenceAgentsRemediation:
		c = s.Components.FenceAgentsRemediation
	case ComponentKeyMachineDeletionRemediation:
		c = s.Components.MachineDeletionRemediation
	default:
		return ComponentStateDisabled
	}
	if c.State == ComponentStateEnabled {
		return ComponentStateEnabled
	}
	return ComponentStateDisabled
}

// ComponentPhase summarizes one component's observed lifecycle state.
type ComponentPhase string

const (
	ComponentPhaseDisabled          ComponentPhase = "Disabled"
	ComponentPhaseProgressing       ComponentPhase = "Progressing"
	ComponentPhaseAvailable         ComponentPhase = "Available"
	ComponentPhaseDegraded          ComponentPhase = "Degraded"
	ComponentPhaseDisableIncomplete ComponentPhase = "DisableIncomplete"
)

const (
	ConditionAvailable   = "Available"
	ConditionProgressing = "Progressing"
	ConditionDegraded    = "Degraded"
)

// DeploymentStatus reports one operand Deployment.
type DeploymentStatus struct {
	Name            string `json:"name"`
	Ready           bool   `json:"ready"`
	ReadyReplicas   int32  `json:"readyReplicas"`
	DesiredReplicas int32  `json:"desiredReplicas"`
}

// ComponentStatus reports one component.
type ComponentStatus struct {
	Name         string         `json:"name"`
	DesiredState ComponentState `json:"desiredState"`
	Phase        ComponentPhase `json:"phase"`
	// +optional
	Deployments []DeploymentStatus `json:"deployments,omitempty"`
	// admissionReady is nil for components without webhooks.
	// +optional
	AdmissionReady *bool `json:"admissionReady,omitempty"`
	// retainedResources lists objects that outlive a manager-level disable: agent DaemonSets and
	// their native configs, and native objects the stopped manager would have reconciled (for
	// example an active NodeMaintenance). Non-empty means DisableIncomplete.
	// +optional
	RetainedResources []string `json:"retainedResources,omitempty"`
	// +optional
	Message string `json:"message,omitempty"`
}

// ImageReference is one pinned image in the release set.
type ImageReference struct {
	Name  string `json:"name"`
	Image string `json:"image"`
}

// WorkloadAvailabilityConfigStatus defines the observed state.
type WorkloadAvailabilityConfigStatus struct {
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// +optional
	Components []ComponentStatus `json:"components,omitempty"`
	// +optional
	InstallNamespace string `json:"installNamespace,omitempty"`
	// +optional
	ReleaseSet []ImageReference `json:"releaseSet,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=wac
// +kubebuilder:printcolumn:name="Available",type=string,JSONPath=`.status.conditions[?(@.type=="Available")].status`
// +kubebuilder:printcolumn:name="Progressing",type=string,JSONPath=`.status.conditions[?(@.type=="Progressing")].status`
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=`.status.conditions[?(@.type=="Degraded")].status`
// +kubebuilder:validation:XValidation:rule="self.metadata.name == 'cluster'",message="WorkloadAvailabilityConfig is a singleton and must be named 'cluster'"

// WorkloadAvailabilityConfig is the cluster-scoped singleton entry point.
type WorkloadAvailabilityConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WorkloadAvailabilityConfigSpec   `json:"spec,omitempty"`
	Status WorkloadAvailabilityConfigStatus `json:"status,omitempty"`
}
```

Keep the generated `WorkloadAvailabilityConfigList` and `init()` registration.

- [ ] **Step 4: Regenerate and run the tests**

Run: `make generate manifests && go test ./api/... -v`
Expected: PASS for the three tests; the CRD YAML contains one `x-kubernetes-validations`
rules and `scope: Cluster`.

- [ ] **Step 5: Write the sample**

```yaml
# config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml
apiVersion: workloadavailability.medik8s.io/v1alpha1
kind: WorkloadAvailabilityConfig
metadata:
  name: cluster
spec:
  components:
    nodeHealthCheck:
      state: Disabled
    selfNodeRemediation:
      state: Disabled
    storageBasedRemediation:
      state: Disabled
```

- [ ] **Step 6: Commit**

```sh
git add -A && git commit -m "wao: define WorkloadAvailabilityConfig API with singleton and POC-scope CEL rules"
```

### Task 3: Fetch the pinned bundles and extract operand manifests

**Files:**
- Use (already present): `release-set.yaml`, `hack/fetch-bundles.py`, `hack/requirements.txt`
- Create: `hack/extract-operand-manifests.py`, `hack/extract_operand_manifests_test.py`
- Create (generated, committed): `internal/operands/manifests/{nhc,snr,sbr,far,mdr,nmo}/*.yaml`, `internal/operands/manifests/provenance.json`, `config/crd/bases/<twelve component CRD files>`, `config/rbac/operand_union_role.yaml`
- Modify: `config/crd/kustomization.yaml`, `config/rbac/kustomization.yaml`, `Makefile`

**Interfaces:**
- Consumes: `.cache/bundles/<nhc|snr|sbr>/manifests/*.yaml` and `fetch.json`, produced by `hack/fetch-bundles.py`.
- Produces: on-disk manifests where the literal placeholder `__WAO_NAMESPACE__` marks the install namespace. Images keep the **upstream** references from the bundle; the renderer swaps in pinned digests. WAO additions are recorded in `provenance.json` under `wao_modifications`: the webhook certificate volume and mount, the webhook Service serving-cert annotation, subject namespace rewrites (D9), the component pod label `workloadavailability.medik8s.io/component=<API key>` on every operand pod template, and any Service selector narrowed because it also matched another component's pods (D10). Extraction fails if two components would produce the same object.
- Produces: file names `NN-<Kind>-<name>.yaml`. `NN` is the apply order: `00` ServiceAccount, `10` ClusterRole, `11` ClusterRoleBinding, `20` Role, `21` RoleBinding, `30` ConfigMap, `40` Service, `50` Deployment, `60` ValidatingWebhookConfiguration, `61` MutatingWebhookConfiguration.
- Produces: webhook configurations `<prefix>-validating-webhook-configuration` and `<prefix>-mutating-webhook-configuration`, and certificate Secrets `<prefix>-webhook-server-cert`, for prefixes `node-healthcheck`, `self-node-remediation`, `fence-agents-remediation` and `node-maintenance-operator`. NMO and NHC have only a validating configuration. SBR and MDR have no webhooks.
- Produces: `config/rbac/operand_union_role.yaml` with ClusterRole `operand-union-role` and ClusterRoleBinding `operand-union-rolebinding` to ServiceAccount `controller-manager` in namespace `system`, which kustomize rewrites.

- [ ] **Step 1: Fetch the bundles**

```sh
.venv/bin/python hack/fetch-bundles.py --release-set release-set.yaml --out .cache/bundles
```

Expected:

```
far: quay.io/medik8s/fence-agents-remediation-operator-bundle@sha256:5416… -> 9 files
mdr: quay.io/medik8s/machine-deletion-remediation-operator-bundle@sha256:b95a… -> 8 files
nhc: quay.io/medik8s/node-healthcheck-operator-bundle@sha256:2a2a… -> 6 files
nmo: quay.io/medik8s/node-maintenance-operator-bundle@sha256:abef… -> 6 files
sbr: quay.io/medik8s/storage-based-remediation-operator-bundle@sha256:1f5c… -> 21 files
snr: quay.io/medik8s/self-node-remediation-operator-bundle@sha256:2e66… -> 10 files
```

Add a Makefile target so others can repeat it:

```make
PYTHON ?= .venv/bin/python
BUNDLE_CACHE ?= .cache/bundles
.PHONY: bundles
bundles:
	$(PYTHON) hack/fetch-bundles.py --release-set release-set.yaml --out $(BUNDLE_CACHE)
```

- [ ] **Step 2: Write the failing test**

```python
# hack/extract_operand_manifests_test.py
import hashlib, json, pathlib, subprocess, sys, tempfile, unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
SCRIPT = HERE / "extract-operand-manifests.py"
CACHE = REPO / ".cache/bundles"
RELEASE_SET = REPO / "release-set.yaml"


def run(out, crd_out, rbac_out, *extra):
    cmd = [sys.executable, str(SCRIPT), "--bundles", str(CACHE), "--release-set", str(RELEASE_SET),
           "--out", str(out), "--crd-out", str(crd_out), "--rbac-out", str(rbac_out), *extra]
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def load_all(directory):
    return {f.name: yaml.safe_load(f.read_text()) for f in sorted(pathlib.Path(directory).glob("*.yaml"))}


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


@unittest.skipUnless((CACHE / "nhc" / "fetch.json").exists(), "run `make bundles` first")
class ExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.tmp.name)
        cls.out, cls.crd_out, cls.rbac_out = root / "manifests", root / "crds", root / "union.yaml"
        run(cls.out, cls.crd_out, cls.rbac_out)
        cls.docs = {c: load_all(cls.out / c) for c in ("nhc", "snr", "sbr", "far", "mdr", "nmo")}
        cls.nhc, cls.snr, cls.sbr = cls.docs["nhc"], cls.docs["snr"], cls.docs["sbr"]
        cls.far, cls.mdr, cls.nmo = cls.docs["far"], cls.docs["mdr"], cls.docs["nmo"]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def kinds(self, docs, kind):
        return [d for d in docs.values() if d["kind"] == kind]

    def test_nhc_manager_and_validating_webhook(self):
        self.assertEqual([d["metadata"]["name"] for d in self.kinds(self.nhc, "Deployment")], ["node-healthcheck-controller-manager"])
        vw = self.kinds(self.nhc, "ValidatingWebhookConfiguration")
        self.assertEqual(len(vw), 1)
        self.assertEqual(vw[0]["metadata"]["name"], "node-healthcheck-validating-webhook-configuration")
        hook = vw[0]["webhooks"][0]
        self.assertEqual(hook["name"], "vnodehealthcheck.kb.io")
        self.assertEqual(hook["failurePolicy"], "Fail")
        self.assertEqual(hook["clientConfig"]["service"], {"name": "node-healthcheck-webhook-service", "namespace": "__WAO_NAMESPACE__",
                                                           "path": "/validate-remediation-medik8s-io-v1alpha1-nodehealthcheck", "port": 443})
        self.assertEqual(vw[0]["metadata"]["annotations"]["service.beta.openshift.io/inject-cabundle"], "true")

    def test_snr_webhooks_split_by_kind_and_keep_policies(self):
        vw = self.kinds(self.snr, "ValidatingWebhookConfiguration")[0]
        mw = self.kinds(self.snr, "MutatingWebhookConfiguration")[0]
        self.assertEqual({w["name"]: w["failurePolicy"] for w in vw["webhooks"]},
                         {"vselfnoderemediation.kb.io": "Ignore", "vselfnoderemediationconfig.kb.io": "Fail",
                          "vselfnoderemediationtemplate.kb.io": "Fail"})
        self.assertEqual([w["name"] for w in mw["webhooks"]], ["mselfnoderemediationtemplate.kb.io"])
        self.assertEqual(mw["metadata"]["name"], "self-node-remediation-mutating-webhook-configuration")

    def test_webhook_deployments_mount_service_ca_certificate(self):
        for docs, dep, secret in ((self.nhc, "node-healthcheck-controller-manager", "node-healthcheck-webhook-server-cert"),
                                  (self.snr, "self-node-remediation-controller-manager", "self-node-remediation-webhook-server-cert")):
            d = next(x for x in self.kinds(docs, "Deployment") if x["metadata"]["name"] == dep)
            vols = {v["name"]: v for v in d["spec"]["template"]["spec"]["volumes"]}
            self.assertEqual(vols["webhook-server-cert"]["secret"]["secretName"], secret)
            manager = next(c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "manager")
            mount = {m["name"]: m for m in manager["volumeMounts"]}["webhook-server-cert"]
            self.assertEqual(mount["mountPath"], "/tmp/k8s-webhook-server/serving-certs")
            self.assertTrue(mount["readOnly"])
            svc = next(s for s in self.kinds(docs, "Service") if s["metadata"]["name"].endswith("webhook-service"))
            self.assertEqual(svc["metadata"]["annotations"]["service.beta.openshift.io/serving-cert-secret-name"], secret)

    def test_sbr_has_no_webhooks_and_agent_binding_namespace_rewritten(self):
        self.assertEqual(self.kinds(self.sbr, "ValidatingWebhookConfiguration") + self.kinds(self.sbr, "MutatingWebhookConfiguration"), [])
        crb = next(x for x in self.kinds(self.sbr, "ClusterRoleBinding") if x["metadata"]["name"] == "sbr-operator-sbr-agent-rolebinding")
        self.assertEqual(crb["subjects"][0]["namespace"], "__WAO_NAMESPACE__")
        sa = next(x for x in self.kinds(self.sbr, "ServiceAccount") if x["metadata"]["name"] == "sbr-operator-sbr-agent")
        self.assertEqual(sa["metadata"]["namespace"], "__WAO_NAMESPACE__")

    def test_csv_permissions_become_rbac_objects(self):
        crb = next(x for x in self.kinds(self.snr, "ClusterRoleBinding") if x["metadata"]["name"] == "self-node-remediation-controller-manager")
        self.assertEqual(crb["subjects"], [{"kind": "ServiceAccount", "name": "self-node-remediation-controller-manager", "namespace": "__WAO_NAMESPACE__"}])
        role = next(x for x in self.kinds(self.snr, "Role") if x["metadata"]["name"] == "self-node-remediation-controller-manager")
        self.assertTrue(any("leases" in r["resources"] for r in role["rules"]))

    def test_images_keep_upstream_references(self):
        text = "".join((self.out / "snr" / n).read_text() for n in self.snr)
        self.assertIn("quay.io/medik8s/self-node-remediation-operator:v0.13.0", text)
        text = "".join((self.out / "sbr" / n).read_text() for n in self.sbr)
        self.assertIn("quay.io/medik8s/storage-based-remediation-agent:v0.3.0", text)

    def test_unknown_upstream_image_fails_extraction(self):
        rs = yaml.safe_load(RELEASE_SET.read_text())
        del rs["components"]["sbr"]["images"]["RELATED_IMAGE_SBR_AGENT"]
        with tempfile.TemporaryDirectory() as d:
            alt = pathlib.Path(d) / "rs.yaml"
            alt.write_text(yaml.safe_dump(rs))
            r = subprocess.run([sys.executable, str(SCRIPT), "--bundles", str(CACHE), "--release-set", str(alt),
                                "--out", f"{d}/m", "--crd-out", f"{d}/c", "--rbac-out", f"{d}/u.yaml"], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("storage-based-remediation-agent:v0.3.0", r.stdout + r.stderr)

    def test_far_and_nmo_webhooks(self):
        far_m = self.kinds(self.far, "MutatingWebhookConfiguration")[0]
        far_v = self.kinds(self.far, "ValidatingWebhookConfiguration")[0]
        self.assertEqual(sorted(w["name"] for w in far_m["webhooks"]), ["mfenceagentsremediation.kb.io", "mfenceagentsremediationtemplate.kb.io"])
        self.assertEqual(sorted(w["name"] for w in far_v["webhooks"]), ["vfenceagentsremediation.kb.io", "vfenceagentsremediationtemplate.kb.io"])
        self.assertTrue(all(w["failurePolicy"] == "Fail" for w in far_m["webhooks"] + far_v["webhooks"]))
        nmo_v = self.kinds(self.nmo, "ValidatingWebhookConfiguration")[0]
        self.assertEqual(nmo_v["metadata"]["name"], "node-maintenance-operator-validating-webhook-configuration")
        self.assertEqual([w["name"] for w in nmo_v["webhooks"]], ["vnodemaintenance.kb.io"])
        self.assertEqual(self.kinds(self.mdr, "ValidatingWebhookConfiguration") + self.kinds(self.mdr, "MutatingWebhookConfiguration"), [])

    def test_every_operand_pod_carries_its_component_label(self):
        keys = {"nhc": "nodeHealthCheck", "snr": "selfNodeRemediation", "sbr": "storageBasedRemediation",
                "far": "fenceAgentsRemediation", "mdr": "machineDeletionRemediation", "nmo": "nodeMaintenance"}
        for comp, docs in self.docs.items():
            for d in self.kinds(docs, "Deployment"):
                self.assertEqual(d["spec"]["template"]["metadata"]["labels"]["workloadavailability.medik8s.io/component"], keys[comp])

    def test_no_service_selects_another_components_pods(self):
        pods = {c: [d["spec"]["template"]["metadata"]["labels"] for d in self.kinds(docs, "Deployment")] for c, docs in self.docs.items()}
        for comp, docs in self.docs.items():
            for svc in self.kinds(docs, "Service"):
                sel = svc["spec"]["selector"]
                for other, labels in pods.items():
                    if other == comp:
                        continue
                    for l in labels:
                        self.assertFalse(all(l.get(k) == v for k, v in sel.items()), f"{comp} Service {svc['metadata']['name']} selects {other} pods")
                self.assertTrue(any(all(l.get(k) == v for k, v in sel.items()) for l in pods[comp]), f"{svc['metadata']['name']} selects none of its own pods")

    def test_mdr_metrics_service_was_narrowed(self):
        svc = next(s for s in self.kinds(self.mdr, "Service") if s["metadata"]["name"] == "machine-deletion-remediation-controller-manager-metrics-service")
        self.assertEqual(svc["spec"]["selector"], {"control-plane": "controller-manager", "workloadavailability.medik8s.io/component": "machineDeletionRemediation"})
        prov = json.loads((self.out / "provenance.json").read_text())
        self.assertTrue(any("selector narrowed" in m for m in prov["bundles"]["mdr"]["wao_modifications"]))
        nhc_svcs = [s["spec"]["selector"] for s in self.kinds(self.nhc, "Service")]
        self.assertTrue(all("workloadavailability.medik8s.io/component" not in s for s in nhc_svcs), "non-overlapping selectors stay verbatim")

    def test_crds_copied_and_union_role_written(self):
        self.assertEqual(len(list(self.crd_out.glob("*.yaml"))), 12)
        docs = list(yaml.safe_load_all(self.rbac_out.read_text()))
        role = next(d for d in docs if d["kind"] == "ClusterRole")
        self.assertEqual(role["metadata"]["name"], "operand-union-role")
        self.assertTrue(any(r.get("resourceNames") == ["privileged"] and "use" in r["verbs"] for r in role["rules"]))
        self.assertTrue(any("validatingwebhookconfigurations" in r.get("resources", []) for r in role["rules"]))

    def test_provenance_and_determinism(self):
        prov = json.loads((self.out / "provenance.json").read_text())
        self.assertEqual(set(prov["bundles"]), {"nhc", "snr", "sbr", "far", "mdr", "nmo"})
        self.assertTrue(prov["bundles"]["nhc"]["bundle"].startswith("quay.io/medik8s/node-healthcheck-operator-bundle@sha256:"))
        for comp in prov["bundles"].values():
            for f, h in comp["outputs"].items():
                self.assertEqual(h, sha(self.out / f))
        with tempfile.TemporaryDirectory() as second:
            root = pathlib.Path(second)
            run(root / "m", root / "c", root / "u.yaml")
            for comp in ("nhc", "snr", "sbr", "far", "mdr", "nmo"):
                for f in (self.out / comp).glob("*.yaml"):
                    self.assertEqual(f.read_text(), (root / "m" / comp / f.name).read_text())

    def test_check_mode_passes_on_committed_outputs(self):
        committed = REPO / "internal/operands/manifests"
        if not committed.exists():
            self.skipTest("committed outputs not generated yet")
        run(committed, REPO / "config/crd/bases", REPO / "config/rbac/operand_union_role.yaml", "--check")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v`
Expected: errors because `hack/extract-operand-manifests.py` does not exist.

- [ ] **Step 4: Write the extraction script**

```python
#!/usr/bin/env python3
"""Extract WAO operand manifests from fetched upstream OLM bundles.

Inputs: .cache/bundles/<component>/manifests (from hack/fetch-bundles.py) and release-set.yaml.
Outputs: deterministic YAML for the Go renderer (go:embed), the component CRDs for the WAO
CSV, and the union ClusterRole that lets WAO create component RBAC (RBAC escalation prevention).

All six operands share one namespace, so a cross-component pass (design brief D10) labels every
operand pod with its component, narrows any Service selector that would also match another
component's pods, and rejects duplicate object identities across components.
"""
import argparse
import copy
import hashlib
import json
import pathlib
import sys

import yaml

NAMESPACE_PLACEHOLDER = "__WAO_NAMESPACE__"
# kustomize placeholder namespaces that bundles sometimes leave in RBAC subjects (D9)
PLACEHOLDER_NAMESPACES = {"system", "sbr-operator-system", "node-healthcheck-operator-system", "self-node-remediation-system"}
NAMESPACED_KINDS = {"Deployment", "Service", "ConfigMap", "Role", "RoleBinding", "ServiceAccount", "Secret"}
WEBHOOK_CERT_DIR = "/tmp/k8s-webhook-server/serving-certs"  # controller-runtime default; upstream managers fall back to it
COMPONENT_LABEL = "workloadavailability.medik8s.io/component"
# Name suffix of the cluster-wide copy of a CSV's namespaced permissions (OLM AllNamespaces behaviour).
ALL_NAMESPACES_SUFFIX = "-all-namespaces"
SERVING_CERT_ANNOTATION = "service.beta.openshift.io/serving-cert-secret-name"
INJECT_CABUNDLE_ANNOTATION = "service.beta.openshift.io/inject-cabundle"
ORDER = {"ServiceAccount": "00", "ClusterRole": "10", "ClusterRoleBinding": "11", "Role": "20", "RoleBinding": "21",
         "ConfigMap": "30", "Service": "40", "Deployment": "50",
         "ValidatingWebhookConfiguration": "60", "MutatingWebhookConfiguration": "61"}

# key: the WorkloadAvailabilityConfig API key, also the value of COMPONENT_LABEL on operand pods.
COMPONENTS = {
    "nhc": {"key": "nodeHealthCheck", "prefix": "node-healthcheck", "webhook_service": "node-healthcheck-webhook-service",
            "webhook_deployment": "node-healthcheck-controller-manager"},
    "snr": {"key": "selfNodeRemediation", "prefix": "self-node-remediation", "webhook_service": "self-node-remediation-webhook-service",
            "webhook_deployment": "self-node-remediation-controller-manager"},
    "sbr": {"key": "storageBasedRemediation", "prefix": "sbr-operator", "webhook_service": None, "webhook_deployment": None},
    "far": {"key": "fenceAgentsRemediation", "prefix": "fence-agents-remediation", "webhook_service": "fence-agents-remediation-webhook-service",
            "webhook_deployment": "fence-agents-remediation-controller-manager"},
    "mdr": {"key": "machineDeletionRemediation", "prefix": "machine-deletion-remediation", "webhook_service": None, "webhook_deployment": None},
    "nmo": {"key": "nodeMaintenance", "prefix": "node-maintenance-operator", "webhook_service": "node-maintenance-operator-webhook-service",
            "webhook_deployment": "node-maintenance-operator-controller-manager"},
}

# Permissions WAO itself needs beyond the component union.
WAO_OWN_RULES = [
    {"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["roles", "rolebindings", "clusterroles", "clusterrolebindings"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch", "bind"]},
    {"apiGroups": ["admissionregistration.k8s.io"], "resources": ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": ["apps"], "resources": ["daemonsets"], "verbs": ["get", "list", "watch"]},
    {"apiGroups": [""], "resources": ["services", "serviceaccounts", "configmaps"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": [""], "resources": ["events"], "verbs": ["create", "patch"]},
]


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def dump(obj):
    return yaml.safe_dump(obj, sort_keys=True, default_flow_style=False, width=4096)


def load_bundle(cache, name):
    root = pathlib.Path(cache) / name
    fetch = json.loads((root / "fetch.json").read_text())
    csv, crds, others, inputs = None, [], [], {}
    for f in sorted((root / "manifests").iterdir()):
        inputs[f.name] = sha256_bytes(f.read_bytes())
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csv = obj
        elif obj["kind"] == "CustomResourceDefinition":
            crds.append((f.name, obj))
        else:
            others.append(obj)
    if csv is None:
        raise SystemExit(f"{name}: no CSV in {root}/manifests")
    return fetch["image"], csv, crds, others, inputs


def clean(obj):
    obj = copy.deepcopy(obj)
    obj.get("metadata", {}).pop("creationTimestamp", None)
    obj.pop("status", None)
    return obj


def with_namespace(obj):
    if obj["kind"] in NAMESPACED_KINDS:
        obj.setdefault("metadata", {})["namespace"] = NAMESPACE_PLACEHOLDER
    return obj


def rewrite_subjects(obj, mods):
    for s in obj.get("subjects", []) or []:
        if s.get("kind") == "ServiceAccount" and s.get("namespace") in PLACEHOLDER_NAMESPACES:
            mods.append(f"{obj['kind']}/{obj['metadata']['name']}: subject namespace {s['namespace']} -> install namespace")
            s["namespace"] = NAMESPACE_PLACEHOLDER
    return obj


def deployments(csv, comp, mods):
    out = []
    for d in csv["spec"]["install"]["spec"]["deployments"]:
        dep = {"apiVersion": "apps/v1", "kind": "Deployment",
               "metadata": {"name": d["name"], "namespace": NAMESPACE_PLACEHOLDER, "labels": d.get("label", {})},
               "spec": copy.deepcopy(d["spec"])}
        if d["name"] == comp["webhook_deployment"]:
            secret = f"{comp['prefix']}-webhook-server-cert"
            pod = dep["spec"]["template"]["spec"]
            pod.setdefault("volumes", []).append({"name": "webhook-server-cert", "secret": {"secretName": secret, "defaultMode": 420}})
            manager = next(c for c in pod["containers"] if c["name"] == "manager")
            manager.setdefault("volumeMounts", []).append({"name": "webhook-server-cert", "mountPath": WEBHOOK_CERT_DIR, "readOnly": True})
            mods.append(f"Deployment/{d['name']}: added service-ca webhook certificate volume {secret} at {WEBHOOK_CERT_DIR}")
        out.append(dep)
    return out


def rbac(csv, mods):
    spec = csv["spec"]["install"]["spec"]
    out, sas = [], set()
    for p in spec.get("permissions", []) or []:
        sa = p["serviceAccountName"]; sas.add(sa)
        subjects = [{"kind": "ServiceAccount", "name": sa, "namespace": NAMESPACE_PLACEHOLDER}]
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                    "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
                    "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": sa},
                    "subjects": copy.deepcopy(subjects)})
        # OLM's OperatorGroup controller (ensureSingletonRBAC) also grants a CSV's namespaced permissions
        # cluster-wide when the OperatorGroup targets all namespaces, the only install mode these CSVs
        # support. Reproduce that copy; the suffix keeps it apart from the clusterPermissions role named after the SA.
        cluster_name = f"{sa}{ALL_NAMESPACES_SUFFIX}"
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
                    "metadata": {"name": cluster_name}, "rules": copy.deepcopy(p["rules"])})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": cluster_name},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": cluster_name},
                    "subjects": copy.deepcopy(subjects)})
        mods.append(f"CSV permissions for {sa} also rendered as ClusterRole/ClusterRoleBinding {cluster_name}, "
                    "as OLM grants them for an AllNamespaces OperatorGroup")
    for p in spec.get("clusterPermissions", []) or []:
        sa = p["serviceAccountName"]; sas.add(sa)
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": sa}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": sa},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": sa},
                    "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": NAMESPACE_PLACEHOLDER}]})
    for d in spec["deployments"]:
        sas.add(d["spec"]["template"]["spec"]["serviceAccountName"])
    for sa in sorted(sas):
        out.append({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER}})
    mods.append("CSV permissions/clusterPermissions rendered as Role/RoleBinding/ClusterRole/ClusterRoleBinding named after each ServiceAccount")
    return out


def webhooks(csv, comp, mods):
    defs = csv["spec"].get("webhookdefinitions") or []
    groups = {"ValidatingAdmissionWebhook": ("ValidatingWebhookConfiguration", "validating"),
              "MutatingAdmissionWebhook": ("MutatingWebhookConfiguration", "mutating")}
    out = []
    for wtype, (kind, suffix) in groups.items():
        hooks = []
        for w in defs:
            if w["type"] != wtype:
                continue
            if w["deploymentName"] != comp["webhook_deployment"]:
                raise SystemExit(f"webhook {w['generateName']} targets unexpected deployment {w['deploymentName']}")
            hooks.append({"name": w["generateName"], "admissionReviewVersions": w["admissionReviewVersions"],
                          "sideEffects": w["sideEffects"], "failurePolicy": w["failurePolicy"], "rules": w["rules"],
                          "clientConfig": {"service": {"name": comp["webhook_service"], "namespace": NAMESPACE_PLACEHOLDER,
                                                       "path": w["webhookPath"], "port": w.get("containerPort", 443)}}})
        if hooks:
            out.append({"apiVersion": "admissionregistration.k8s.io/v1", "kind": kind,
                        "metadata": {"name": f"{comp['prefix']}-{suffix}-webhook-configuration",
                                     "annotations": {INJECT_CABUNDLE_ANNOTATION: "true"}},
                        "webhooks": sorted(hooks, key=lambda h: h["name"])})
            mods.append(f"{kind}: generated from CSV webhookdefinitions with service-ca CA bundle injection")
    return out


def other_objects(others, comp, mods):
    out = []
    for obj in others:
        obj = with_namespace(clean(obj))
        rewrite_subjects(obj, mods)
        if comp["webhook_service"] and obj["kind"] == "Service" and obj["metadata"]["name"] == comp["webhook_service"]:
            obj["metadata"].setdefault("annotations", {})[SERVING_CERT_ANNOTATION] = f"{comp['prefix']}-webhook-server-cert"
            mods.append(f"Service/{obj['metadata']['name']}: added {SERVING_CERT_ANNOTATION}")
        out.append(obj)
    return out


def matches(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


def isolate(rendered):
    """Cross-component pass (D10). rendered: {component: (objects, mods)}; mutates in place."""
    pod_labels = {}
    for name, (objects, mods) in rendered.items():
        key = COMPONENTS[name]["key"]
        for o in objects:
            if o["kind"] == "Deployment":
                labels = o["spec"]["template"]["metadata"].setdefault("labels", {})
                labels[COMPONENT_LABEL] = key
                pod_labels.setdefault(name, []).append(labels)
                mods.append(f"Deployment/{o['metadata']['name']}: pod template labeled {COMPONENT_LABEL}={key}")
    for name, (objects, mods) in rendered.items():
        key = COMPONENTS[name]["key"]
        for o in objects:
            if o["kind"] != "Service":
                continue
            selector = o["spec"].get("selector") or {}
            foreign = sorted(other for other, labels in pod_labels.items()
                             if other != name and any(matches(selector, l) for l in labels))
            if foreign:
                selector[COMPONENT_LABEL] = key
                mods.append(f"Service/{o['metadata']['name']}: selector narrowed with {COMPONENT_LABEL}={key}; it also matched {', '.join(foreign)} pods")
    seen = {}
    for name, (objects, _) in rendered.items():
        for o in objects:
            ident = (o["kind"], o["metadata"].get("namespace", ""), o["metadata"]["name"])
            if ident in seen:
                raise SystemExit(f"{ident} is produced by both {seen[ident]} and {name}")
            seen[ident] = name


def check_images(name, files, release_set):
    """Every image reference in the output must be an upstream reference listed in release-set.yaml."""
    known = {img["upstream"] for img in release_set["components"][name]["images"].values()}
    found = set()
    for text in files.values():
        for line in text.splitlines():
            s = line.strip().removeprefix("- ")
            for key in ("image: ", "value: "):
                if s.startswith(key) and "quay.io/" in s:
                    found.add(s[len(key):].strip("'\""))
    unknown = sorted(found - known)
    if unknown:
        raise SystemExit(f"{name}: images not listed in release-set.yaml: {unknown}")
    missing = sorted(known - found)
    if missing:
        raise SystemExit(f"{name}: release-set.yaml images not referenced by the bundle: {missing}")


def filename(obj):
    return f"{ORDER[obj['kind']]}-{obj['kind']}-{obj['metadata']['name']}.yaml"


def write_tree(target, files, check, ignore_extra=False):
    target = pathlib.Path(target)
    if not check:
        target.mkdir(parents=True, exist_ok=True)
        if not ignore_extra:
            for stale in target.glob("*.yaml"):
                stale.unlink()
    problems = []
    for name, text in files.items():
        p = target / name
        if check:
            if not p.exists() or p.read_text() != text:
                problems.append(str(p))
        else:
            p.write_text(text)
    if check and not ignore_extra:
        problems.extend(sorted(str(p) for p in target.glob("*.yaml") if p.name not in files))
    return problems


def union_role(csvs):
    seen, rules = set(), []
    for csv in csvs:
        spec = csv["spec"]["install"]["spec"]
        for p in (spec.get("permissions") or []) + (spec.get("clusterPermissions") or []):
            for r in p["rules"]:
                key = json.dumps(r, sort_keys=True)
                if key not in seen:
                    seen.add(key); rules.append(r)
    for r in WAO_OWN_RULES:
        key = json.dumps(r, sort_keys=True)
        if key not in seen:
            seen.add(key); rules.append(r)
    rules.sort(key=lambda r: json.dumps(r, sort_keys=True))
    role = {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "operand-union-role"}, "rules": rules}
    binding = {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "operand-union-rolebinding"},
               "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "operand-union-role"},
               "subjects": [{"kind": "ServiceAccount", "name": "controller-manager", "namespace": "system"}]}
    return "---\n".join(dump(x) for x in (role, binding))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundles", required=True, help=".cache/bundles")
    ap.add_argument("--release-set", required=True)
    ap.add_argument("--out", required=True, help="internal/operands/manifests")
    ap.add_argument("--crd-out", required=True, help="config/crd/bases")
    ap.add_argument("--rbac-out", required=True, help="config/rbac/operand_union_role.yaml")
    ap.add_argument("--check", action="store_true", help="verify outputs are current instead of writing")
    args = ap.parse_args()
    release_set = yaml.safe_load(pathlib.Path(args.release_set).read_text())

    provenance = {"generator": "hack/extract-operand-manifests.py", "namespace_placeholder": NAMESPACE_PLACEHOLDER, "bundles": {}}
    csvs, crd_files, problems, rendered, meta = [], {}, [], {}, {}
    for name, comp in COMPONENTS.items():
        bundle_ref, csv, crds, others, inputs = load_bundle(args.bundles, name)
        if bundle_ref != release_set["components"][name]["bundle"]:
            raise SystemExit(f"{name}: cached bundle {bundle_ref} does not match release-set.yaml; run `make bundles`")
        csvs.append(csv)
        mods = []
        objects = rbac(csv, mods) + other_objects(others, comp, mods) + deployments(csv, comp, mods) + webhooks(csv, comp, mods)
        rendered[name] = (objects, mods)
        meta[name] = (bundle_ref, csv["metadata"]["name"], inputs, crds)
        for crd_name, crd in crds:
            crd_files[crd_name] = dump(clean(crd))
    isolate(rendered)
    for name, (objects, mods) in rendered.items():
        files = {filename(o): dump(o) for o in objects}
        if len(files) != len(objects):
            raise SystemExit(f"{name}: duplicate output filenames")
        check_images(name, files, release_set)
        problems += write_tree(pathlib.Path(args.out) / name, files, args.check)
        bundle_ref, csv_name, inputs, crds = meta[name]
        provenance["bundles"][name] = {
            "bundle": bundle_ref, "csv": csv_name, "inputs": inputs,
            "outputs": {f"{name}/{fn}": sha256_bytes(text.encode()) for fn, text in sorted(files.items())},
            "crds": [c for c, _ in crds], "wao_modifications": sorted(set(mods)),
        }
    # The CRD directory also holds the controller-gen CRD for WorkloadAvailabilityConfig; never delete or flag it.
    problems += write_tree(args.crd_out, crd_files, args.check, ignore_extra=True)
    union = union_role(csvs)
    prov_text = json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    if args.check:
        if pathlib.Path(args.rbac_out).read_text() != union:
            problems.append(args.rbac_out)
        if (pathlib.Path(args.out) / "provenance.json").read_text() != prov_text:
            problems.append(str(pathlib.Path(args.out) / "provenance.json"))
        if problems:
            print("STALE OUTPUTS:\n" + "\n".join(problems)); sys.exit(1)
        print("outputs current")
        return
    pathlib.Path(args.rbac_out).write_text(union)
    (pathlib.Path(args.out) / "provenance.json").write_text(prov_text)
    print(f"wrote {sum(len(b['outputs']) for b in provenance['bundles'].values())} manifests, {len(crd_files)} CRDs, union role")


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run the tests**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v`
Expected: all PASS except `test_check_mode_passes_on_committed_outputs`, which is skipped until Step 6.

- [ ] **Step 6: Generate the committed outputs and wire kustomize**

Add the Makefile targets:

```make
EXTRACT = $(PYTHON) hack/extract-operand-manifests.py --bundles $(BUNDLE_CACHE) --release-set release-set.yaml --out internal/operands/manifests --crd-out config/crd/bases --rbac-out config/rbac/operand_union_role.yaml
.PHONY: operand-manifests operand-manifests-check
operand-manifests:
	$(EXTRACT)
operand-manifests-check:
	$(EXTRACT) --check
```

Run `make operand-manifests`. Expected: `wrote 78 manifests, 12 CRDs, union role`. `provenance.json` must show exactly one narrowed selector, on `machine-deletion-remediation-controller-manager-metrics-service`, because its upstream selector `control-plane: controller-manager` also matches the FAR, NMO, SBR and SNR manager pods.

Edit `config/crd/kustomization.yaml` `resources:` to list the controller-gen file `workloadavailability.medik8s.io_workloadavailabilityconfigs.yaml` plus the twelve extracted files:
- `remediation.medik8s.io_nodehealthchecks.yaml`
- `self-node-remediation.medik8s.io_selfnoderemediationconfigs.yaml`
- `self-node-remediation.medik8s.io_selfnoderemediations.yaml`
- `self-node-remediation.medik8s.io_selfnoderemediationtemplates.yaml`
- `storage-based-remediation.medik8s.io_storagebasedremediationconfigs.yaml`
- `storage-based-remediation.medik8s.io_storagebasedremediations.yaml`
- `storage-based-remediation.medik8s.io_storagebasedremediationtemplates.yaml`
- `fence-agents-remediation.medik8s.io_fenceagentsremediations.yaml`
- `fence-agents-remediation.medik8s.io_fenceagentsremediationtemplates.yaml`
- `machine-deletion-remediation.medik8s.io_machinedeletionremediations.yaml`
- `machine-deletion-remediation.medik8s.io_machinedeletionremediationtemplates.yaml`
- `nodemaintenance.medik8s.io_nodemaintenances.yaml`

Add `- operand_union_role.yaml` to `config/rbac/kustomization.yaml`.

- [ ] **Step 7: Re-run the tests and the kustomize build**

Run: `.venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v && make operand-manifests-check && bin/kustomize build config/crd | grep -c '^kind: CustomResourceDefinition'`
Expected: all tests PASS with none skipped, then `outputs current`, then `13`.

- [ ] **Step 8: Commit**

```sh
git add -A && git commit -m "wao: extract the six operand manifest sets, CRDs and union role from pinned upstream bundles"
```

### Task 4: Image set, component registry and operand renderer

**Files:**
- Create: `internal/images/images.go`, `internal/images/images_test.go`
- Create: `internal/components/component.go`, `nhc.go`, `snr.go`, `sbr.go`, `far.go`, `mdr.go`, `nmo.go`, `components_test.go`
- Create: `internal/operands/embed.go`, `render.go`, `render_test.go`
- Read: `internal/operands/manifests/**` (from Task 3)

**Interfaces:**
- Consumes: manifest files and placeholder `__WAO_NAMESPACE__` from Task 3 (images still upstream tag references); API key
  constants from Task 2.
- Produces:
  - `images.Set` (`map[string]string`), `images.FromEnv(lookup func(string) (string, bool)) (Set, error)`,
    `images.Required []string`, `(Set) Get(env string) string`, `(Set) Sorted() []string`,
    constants `images.NHCManager = "RELATED_IMAGE_NHC_MANAGER"`, `SNRManager`, `SBRManager`, `SBRAgent`, `FARManager`, `MDRManager`, `NMOManager`.
  - `components.Definition{Key, ShortName, ManifestDir string; Deployments []string; Images []ImageBinding; Webhooks []WebhookConfiguration; AgentOwners, ManagedKinds []ResourceKind}`,
    `components.ImageBinding{Env, Original string}`, `components.WebhookConfiguration{Kind, Name string}`,
    `components.ResourceKind{Group, Version, Kind string}`, `components.All() []Definition` (NHC, SNR, SBR, FAR, MDR, NMO),
    `components.ByKey(key string) (Definition, bool)`.
  - `operands.Render(def components.Definition, namespace string, imgs images.Set) ([]*unstructured.Unstructured, error)`,
    `operands.Load(dir string) (map[string][]byte, error)`, constants `operands.NamespacePlaceholder`,
    `operands.LabelManagedBy = "app.kubernetes.io/managed-by"`, `operands.ManagedByValue = "workload-availability-operator"`,
    `operands.LabelComponent = "workloadavailability.medik8s.io/component"`, `operands.IsNamespaced(kind string) bool`.

- [ ] **Step 1: Write the failing tests**

```go
// internal/images/images_test.go
package images

import (
	"strings"
	"testing"
)

func lookupFrom(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestFromEnvReportsEveryMissingVariable(t *testing.T) {
	_, err := FromEnv(lookupFrom(map[string]string{NHCManager: "x"}))
	if err == nil {
		t.Fatal("expected error")
	}
	for _, k := range []string{SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager} {
		if !strings.Contains(err.Error(), k) {
			t.Errorf("error %q does not name %s", err, k)
		}
	}
	if strings.Contains(err.Error(), NHCManager) {
		t.Errorf("error should not name the present variable: %q", err)
	}
}

func TestFromEnvRejectsBlankValues(t *testing.T) {
	m := map[string]string{}
	for _, k := range Required {
		m[k] = "img"
	}
	m[SBRAgent] = "  "
	if _, err := FromEnv(lookupFrom(m)); err == nil || !strings.Contains(err.Error(), SBRAgent) {
		t.Fatalf("expected error naming %s, got %v", SBRAgent, err)
	}
}

func TestFromEnvReturnsAllValuesSorted(t *testing.T) {
	m := map[string]string{}
	for i, k := range Required {
		m[k] = "img" + string(rune('a'+i))
	}
	s, err := FromEnv(lookupFrom(m))
	if err != nil {
		t.Fatal(err)
	}
	if s.Get(SNRManager) != m[SNRManager] {
		t.Fatalf("Get mismatch")
	}
	keys := s.Sorted()
	if len(keys) != len(Required) || keys[0] != FARManager {
		t.Fatalf("Sorted() = %v", keys)
	}
}
```

```go
// internal/components/components_test.go
package components_test

import (
	"strings"
	"testing"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/operands"
)

func TestRegistryKeysMatchAPI(t *testing.T) {
	want := []string{v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentKeyStorageBasedRemediation,
		v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance}
	all := components.All()
	if len(all) != len(want) {
		t.Fatalf("All() has %d entries, want %d", len(all), len(want))
	}
	for i, d := range all {
		if d.Key != want[i] {
			t.Errorf("All()[%d].Key = %q, want %q", i, d.Key, want[i])
		}
		if got, ok := components.ByKey(d.Key); !ok || got.ShortName != d.ShortName {
			t.Errorf("ByKey(%q) mismatch", d.Key)
		}
	}
	if len(want) != len(v1alpha1.AllComponentKeys) {
		t.Fatalf("registry covers %d of %d API keys", len(want), len(v1alpha1.AllComponentKeys))
	}
}

func TestEveryDefinitionMatchesItsManifests(t *testing.T) {
	for _, d := range components.All() {
		files, err := operands.Load(d.ManifestDir)
		if err != nil || len(files) == 0 {
			t.Fatalf("%s: Load(%q) = %d files, %v", d.Key, d.ManifestDir, len(files), err)
		}
		var all strings.Builder
		for _, b := range files {
			all.Write(b)
		}
		text := all.String()
		for _, img := range d.Images {
			if !strings.Contains(text, img.Original) {
				t.Errorf("%s: original image for %s not found in manifests", d.Key, img.Env)
			}
		}
		for _, dep := range d.Deployments {
			if !strings.Contains(text, "name: "+dep+"\n") {
				t.Errorf("%s: deployment %s not found in manifests", d.Key, dep)
			}
		}
		for _, wh := range d.Webhooks {
			if !strings.Contains(text, "kind: "+wh.Kind+"\n") || !strings.Contains(text, "name: "+wh.Name+"\n") {
				t.Errorf("%s: webhook configuration %s/%s not found", d.Key, wh.Kind, wh.Name)
			}
		}
	}
}

func TestSNRAndSBRDeclareAgentOwners(t *testing.T) {
	snr, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	sbr, _ := components.ByKey(v1alpha1.ComponentKeyStorageBasedRemediation)
	nhc, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	if len(snr.AgentOwners) != 1 || snr.AgentOwners[0].Kind != "SelfNodeRemediationConfig" {
		t.Errorf("SNR agent owners = %+v", snr.AgentOwners)
	}
	if len(sbr.AgentOwners) != 1 || sbr.AgentOwners[0].Kind != "StorageBasedRemediationConfig" {
		t.Errorf("SBR agent owners = %+v", sbr.AgentOwners)
	}
	if len(nhc.AgentOwners) != 0 {
		t.Errorf("NHC has no agents, got %+v", nhc.AgentOwners)
	}
}

func TestEveryComponentDeclaresManagedKinds(t *testing.T) {
	want := map[string]string{
		v1alpha1.ComponentKeyNodeHealthCheck: "NodeHealthCheck", v1alpha1.ComponentKeySelfNodeRemediation: "SelfNodeRemediation",
		v1alpha1.ComponentKeyStorageBasedRemediation: "StorageBasedRemediation", v1alpha1.ComponentKeyFenceAgentsRemediation: "FenceAgentsRemediation",
		v1alpha1.ComponentKeyMachineDeletionRemediation: "MachineDeletionRemediation", v1alpha1.ComponentKeyNodeMaintenance: "NodeMaintenance",
	}
	for _, d := range components.All() {
		if len(d.ManagedKinds) != 1 || d.ManagedKinds[0].Kind != want[d.Key] {
			t.Errorf("%s ManagedKinds = %+v, want %s", d.Key, d.ManagedKinds, want[d.Key])
		}
	}
}
```

```go
// internal/operands/render_test.go
package operands_test

import (
	"strings"
	"testing"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/images"
	"github.com/jwmatthews/wao_poc/internal/operands"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func testImages() images.Set {
	s := images.Set{}
	for _, k := range images.Required {
		s[k] = "example.test/" + strings.ToLower(k) + "@sha256:0000000000000000000000000000000000000000000000000000000000000000"
	}
	return s
}

func find(t *testing.T, objs []*unstructured.Unstructured, kind, name string) *unstructured.Unstructured {
	for _, o := range objs {
		if o.GetKind() == kind && o.GetName() == name {
			return o
		}
	}
	t.Fatalf("%s/%s not rendered", kind, name)
	return nil
}

func TestRenderNHCReplacesNamespaceImagesAndLabels(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	objs, err := operands.Render(def, "wao-ns", testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "node-healthcheck-controller-manager")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	image := containers[0].(map[string]interface{})["image"].(string)
	if image != testImages().Get(images.NHCManager) {
		t.Fatalf("manager image = %q", image)
	}
	if strings.Contains(image, ":v0.12.0") {
		t.Fatalf("upstream tag was not replaced: %q", image)
	}
	for _, o := range objs {
		if o.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue || o.GetLabels()[operands.LabelComponent] != def.Key {
			t.Errorf("%s/%s missing WAO labels: %v", o.GetKind(), o.GetName(), o.GetLabels())
		}
		if operands.IsNamespaced(o.GetKind()) && o.GetNamespace() != "wao-ns" {
			t.Errorf("%s/%s namespace = %q", o.GetKind(), o.GetName(), o.GetNamespace())
		}
	}
	vw := find(t, objs, "ValidatingWebhookConfiguration", "node-healthcheck-validating-webhook-configuration")
	hooks, _, _ := unstructured.NestedSlice(vw.Object, "webhooks")
	svc := hooks[0].(map[string]interface{})["clientConfig"].(map[string]interface{})["service"].(map[string]interface{})
	if svc["namespace"] != "wao-ns" || svc["name"] != "node-healthcheck-webhook-service" {
		t.Fatalf("webhook service = %v", svc)
	}
}

func TestRenderOrdersRBACBeforeWorkloadsAndWebhooksLast(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	objs, err := operands.Render(def, "wao-ns", testImages())
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, o := range objs {
		if _, seen := pos[o.GetKind()]; !seen {
			pos[o.GetKind()] = i
		}
	}
	if !(pos["ServiceAccount"] < pos["ClusterRole"] && pos["ClusterRole"] < pos["ClusterRoleBinding"] && pos["Service"] < pos["Deployment"] && pos["Deployment"] < pos["ValidatingWebhookConfiguration"] && pos["Deployment"] < pos["MutatingWebhookConfiguration"]) {
		t.Fatalf("unexpected order: %v", pos)
	}
}

func TestRenderSNRReplacesAgentImageEnv(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	objs, err := operands.Render(def, "wao-ns", testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "self-node-remediation-controller-manager")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	env, _, _ := unstructured.NestedSlice(containers[0].(map[string]interface{}), "env")
	for _, e := range env {
		m := e.(map[string]interface{})
		if m["name"] == "SELF_NODE_REMEDIATION_IMAGE" && m["value"] != testImages().Get(images.SNRManager) {
			t.Fatalf("SELF_NODE_REMEDIATION_IMAGE = %v", m["value"])
		}
	}
	crb := find(t, objs, "ClusterRoleBinding", "self-node-remediation-controller-manager")
	subjects, _, _ := unstructured.NestedSlice(crb.Object, "subjects")
	if subjects[0].(map[string]interface{})["namespace"] != "wao-ns" {
		t.Fatalf("subject namespace not rewritten: %v", subjects[0])
	}
}

func TestRenderFailsWhenImageMissing(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyStorageBasedRemediation)
	imgs := testImages()
	delete(imgs, images.SBRAgent)
	if _, err := operands.Render(def, "wao-ns", imgs); err == nil || !strings.Contains(err.Error(), images.SBRAgent) {
		t.Fatalf("expected error naming %s, got %v", images.SBRAgent, err)
	}
}

func TestRenderLeavesNoPlaceholder(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, "wao-ns", testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			b, _ := o.MarshalJSON()
			if strings.Contains(string(b), operands.NamespacePlaceholder) {
				t.Errorf("%s: %s/%s still contains placeholder", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/... 2>&1 | head -20`
Expected: compile errors for undefined packages/symbols.

- [ ] **Step 3: Implement `internal/images`**

```go
// internal/images/images.go
package images

import (
	"fmt"
	"sort"
	"strings"
)

const (
	NHCManager = "RELATED_IMAGE_NHC_MANAGER"
	SNRManager = "RELATED_IMAGE_SNR_MANAGER"
	SBRManager = "RELATED_IMAGE_SBR_MANAGER"
	SBRAgent   = "RELATED_IMAGE_SBR_AGENT"
	FARManager = "RELATED_IMAGE_FAR_MANAGER"
	MDRManager = "RELATED_IMAGE_MDR_MANAGER"
	NMOManager = "RELATED_IMAGE_NMO_MANAGER"
)

// Required lists every image environment variable the operator needs at startup.
var Required = []string{NHCManager, SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager}

// Set maps RELATED_IMAGE_* names to pinned image references.
type Set map[string]string

// FromEnv builds a Set from the given lookup, failing if any required value is absent or blank.
func FromEnv(lookup func(string) (string, bool)) (Set, error) {
	s := Set{}
	var missing []string
	for _, k := range Required {
		v, ok := lookup(k)
		if !ok || strings.TrimSpace(v) == "" {
			missing = append(missing, k)
			continue
		}
		s[k] = v
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("missing required image environment variables: %s", strings.Join(missing, ", "))
	}
	return s, nil
}

// Get returns the image for an environment variable name, or "".
func (s Set) Get(env string) string { return s[env] }

// Sorted returns the variable names in sorted order.
func (s Set) Sorted() []string {
	keys := make([]string, 0, len(s))
	for k := range s {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
```

- [ ] **Step 4: Implement `internal/components`**

```go
// internal/components/component.go
package components

// ImageBinding maps an operator image variable to the literal upstream image reference found in
// the extracted manifests; the renderer replaces Original with the pinned value from the image set.
type ImageBinding struct {
	Env      string
	Original string
}

// WebhookConfiguration names an admission configuration rendered for the component.
type WebhookConfiguration struct {
	Kind string // ValidatingWebhookConfiguration or MutatingWebhookConfiguration
	Name string
}

// ResourceKind identifies a native API kind of a component.
type ResourceKind struct {
	Group, Version, Kind string
}

// Definition describes one operand component.
type Definition struct {
	Key         string // API key, e.g. nodeHealthCheck
	ShortName   string // nhc
	ManifestDir string // directory under internal/operands/manifests
	Deployments []string
	Images      []ImageBinding
	Webhooks    []WebhookConfiguration
	// AgentOwners are config kinds, in the install namespace, whose DaemonSets are node agents
	// that keep running after the manager is removed.
	AgentOwners []ResourceKind
	// ManagedKinds are native kinds the manager reconciles (and may hold finalizers on). Objects
	// of these kinds that exist anywhere in the cluster while the component is Disabled are
	// no longer reconciled and are reported as retained.
	ManagedKinds []ResourceKind
}

// All returns the POC operand set in reconcile order.
func All() []Definition { return []Definition{NHC(), SNR(), SBR(), FAR(), MDR(), NMO()} }

// ByKey finds a definition by API key.
func ByKey(key string) (Definition, bool) {
	for _, d := range All() {
		if d.Key == key {
			return d, true
		}
	}
	return Definition{}, false
}
```

```go
// internal/components/nhc.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func NHC() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeHealthCheck, ShortName: "nhc", ManifestDir: "nhc",
		Deployments: []string{"node-healthcheck-controller-manager"},
		Images: []ImageBinding{
			{Env: images.NHCManager, Original: "quay.io/medik8s/node-healthcheck-operator:v0.12.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-healthcheck-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "remediation.medik8s.io", Version: "v1alpha1", Kind: "NodeHealthCheck"}},
	}
}
```

```go
// internal/components/snr.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func SNR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeySelfNodeRemediation, ShortName: "snr", ManifestDir: "snr",
		Deployments: []string{"self-node-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.SNRManager, Original: "quay.io/medik8s/self-node-remediation-operator:v0.13.0"},
		},
		Webhooks: []WebhookConfiguration{
			{Kind: "ValidatingWebhookConfiguration", Name: "self-node-remediation-validating-webhook-configuration"},
			{Kind: "MutatingWebhookConfiguration", Name: "self-node-remediation-mutating-webhook-configuration"},
		},
		AgentOwners:  []ResourceKind{{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediationConfig"}},
		ManagedKinds: []ResourceKind{{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediation"}},
	}
}
```

```go
// internal/components/sbr.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func SBR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyStorageBasedRemediation, ShortName: "sbr", ManifestDir: "sbr",
		Deployments: []string{"sbr-operator-controller-manager"},
		Images: []ImageBinding{
			{Env: images.SBRManager, Original: "quay.io/medik8s/storage-based-remediation-operator:v0.3.0"},
			{Env: images.SBRAgent, Original: "quay.io/medik8s/storage-based-remediation-agent:v0.3.0"},
		},
		AgentOwners:  []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediationConfig"}},
		ManagedKinds: []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediation"}},
	}
}
```

```go
// internal/components/far.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func FAR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyFenceAgentsRemediation, ShortName: "far", ManifestDir: "far",
		Deployments: []string{"fence-agents-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.FARManager, Original: "quay.io/medik8s/fence-agents-remediation-operator:v0.8.0"},
		},
		Webhooks: []WebhookConfiguration{
			{Kind: "ValidatingWebhookConfiguration", Name: "fence-agents-remediation-validating-webhook-configuration"},
			{Kind: "MutatingWebhookConfiguration", Name: "fence-agents-remediation-mutating-webhook-configuration"},
		},
		ManagedKinds: []ResourceKind{{Group: "fence-agents-remediation.medik8s.io", Version: "v1alpha1", Kind: "FenceAgentsRemediation"}},
	}
}
```

```go
// internal/components/mdr.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func MDR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyMachineDeletionRemediation, ShortName: "mdr", ManifestDir: "mdr",
		Deployments: []string{"machine-deletion-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.MDRManager, Original: "quay.io/medik8s/machine-deletion-remediation-operator:v0.7.0"},
		},
		ManagedKinds: []ResourceKind{{Group: "machine-deletion-remediation.medik8s.io", Version: "v1alpha1", Kind: "MachineDeletionRemediation"}},
	}
}
```

```go
// internal/components/nmo.go
package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func NMO() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeMaintenance, ShortName: "nmo", ManifestDir: "nmo",
		Deployments: []string{"node-maintenance-operator-controller-manager"},
		Images: []ImageBinding{
			{Env: images.NMOManager, Original: "quay.io/medik8s/node-maintenance-operator:v0.21.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-maintenance-operator-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "nodemaintenance.medik8s.io", Version: "v1beta1", Kind: "NodeMaintenance"}},
	}
}
```

- [ ] **Step 5: Implement `internal/operands`**

```go
// internal/operands/embed.go
package operands

import (
	"embed"
	"fmt"
	"path"
	"sort"
)

//go:embed manifests
var manifests embed.FS

// Load returns the YAML files of one component directory keyed by file name.
func Load(dir string) (map[string][]byte, error) {
	entries, err := manifests.ReadDir(path.Join("manifests", dir))
	if err != nil {
		return nil, fmt.Errorf("manifest directory %q: %w", dir, err)
	}
	out := map[string][]byte{}
	for _, e := range entries {
		if e.IsDir() || path.Ext(e.Name()) != ".yaml" {
			continue
		}
		b, err := manifests.ReadFile(path.Join("manifests", dir, e.Name()))
		if err != nil {
			return nil, err
		}
		out[e.Name()] = b
	}
	return out, nil
}

func sortedNames(m map[string][]byte) []string {
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
```

```go
// internal/operands/render.go
package operands

import (
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"

	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/images"
)

const (
	NamespacePlaceholder = "__WAO_NAMESPACE__"
	LabelManagedBy       = "app.kubernetes.io/managed-by"
	ManagedByValue       = "workload-availability-operator"
	LabelComponent       = "workloadavailability.medik8s.io/component"
)

var namespacedKinds = map[string]bool{"Deployment": true, "Service": true, "ConfigMap": true, "Role": true,
	"RoleBinding": true, "ServiceAccount": true, "Secret": true}

var kindOrder = map[string]int{"ServiceAccount": 0, "ClusterRole": 10, "ClusterRoleBinding": 11, "Role": 20,
	"RoleBinding": 21, "ConfigMap": 30, "Service": 40, "Deployment": 50,
	"ValidatingWebhookConfiguration": 60, "MutatingWebhookConfiguration": 61}

// IsNamespaced reports whether a rendered kind lives in the install namespace.
func IsNamespaced(kind string) bool { return namespacedKinds[kind] }

// Render produces the component's objects for one install namespace and image set,
// sorted so that RBAC precedes workloads and admission configurations come last.
func Render(def components.Definition, namespace string, imgs images.Set) ([]*unstructured.Unstructured, error) {
	files, err := Load(def.ManifestDir)
	if err != nil {
		return nil, err
	}
	var out []*unstructured.Unstructured
	for _, name := range sortedNames(files) {
		text := strings.ReplaceAll(string(files[name]), NamespacePlaceholder, namespace)
		for _, b := range def.Images {
			img := imgs.Get(b.Env)
			if img == "" {
				return nil, fmt.Errorf("%s: no image configured for %s", def.Key, b.Env)
			}
			text = strings.ReplaceAll(text, b.Original, img)
		}
		if strings.Contains(text, NamespacePlaceholder) {
			return nil, fmt.Errorf("%s/%s: unresolved namespace placeholder", def.Key, name)
		}
		j, err := yaml.YAMLToJSON([]byte(text))
		if err != nil {
			return nil, fmt.Errorf("%s/%s: %w", def.Key, name, err)
		}
		u := &unstructured.Unstructured{}
		if err := u.UnmarshalJSON(j); err != nil {
			return nil, fmt.Errorf("%s/%s: %w", def.Key, name, err)
		}
		if _, known := kindOrder[u.GetKind()]; !known {
			return nil, fmt.Errorf("%s/%s: unsupported kind %s", def.Key, name, u.GetKind())
		}
		if IsNamespaced(u.GetKind()) && u.GetNamespace() != namespace {
			return nil, fmt.Errorf("%s/%s: namespace %q, want %q", def.Key, name, u.GetNamespace(), namespace)
		}
		labels := u.GetLabels()
		if labels == nil {
			labels = map[string]string{}
		}
		labels[LabelManagedBy] = ManagedByValue
		labels[LabelComponent] = def.Key
		u.SetLabels(labels)
		out = append(out, u)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if kindOrder[out[i].GetKind()] != kindOrder[out[j].GetKind()] {
			return kindOrder[out[i].GetKind()] < kindOrder[out[j].GetKind()]
		}
		return out[i].GetName() < out[j].GetName()
	})
	return out, nil
}
```

- [ ] **Step 6: Run the tests**

Run: `go test ./internal/images/... ./internal/components/... ./internal/operands/... -v`
Expected: PASS. If `TestEveryDefinitionMatchesItsManifests` fails on a webhook name,
the extraction script's `prefix` and the Go `Webhooks` names disagree; fix the Go
side to match the file on disk (the manifests are the source of truth).

- [ ] **Step 7: Commit**

```sh
git add -A && git commit -m "wao: add image set, component registry and operand renderer"
```

### Task 5: WorkloadAvailabilityConfig controller with envtest coverage

**Files:**
- Modify: `internal/controller/workloadavailabilityconfig_controller.go`
- Create: `internal/controller/status.go`, `internal/controller/status_test.go`
- Modify: `internal/controller/suite_test.go`, `internal/controller/workloadavailabilityconfig_controller_test.go`

**Interfaces:**
- Consumes: `operands.Render`, `components.All`, `images.Set`, API types.
- Produces: `WorkloadAvailabilityConfigReconciler{Client, Scheme, Namespace string, Images images.Set}`,
  `const Finalizer = "workloadavailability.medik8s.io/finalizer"`, `const FieldOwner = "workload-availability-operator"`,
  `func (r *WorkloadAvailabilityConfigReconciler) SetupWithManager(mgr ctrl.Manager) error`,
  `func summarize(existing []metav1.Condition, components []v1alpha1.ComponentStatus, reconcileErr error, generation int64) []metav1.Condition` (in `status.go`). It starts from the existing conditions so an unchanged condition keeps its `lastTransitionTime`; rebuilding conditions from scratch rewrites status on every reconcile and retriggers the controller in a loop.

- [ ] **Step 1: Write the failing status unit test**

```go
// internal/controller/status_test.go
package controller

import (
	"errors"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
)

func cond(conds []metav1.Condition, t string) metav1.ConditionStatus {
	c := meta.FindStatusCondition(conds, t)
	if c == nil {
		return "missing"
	}
	return c.Status
}

func TestSummarizeAllDisabledIsAvailable(t *testing.T) {
	conds := summarize(nil, []v1alpha1.ComponentStatus{{Name: "nodeHealthCheck", Phase: v1alpha1.ComponentPhaseDisabled}}, nil, 3)
	if cond(conds, v1alpha1.ConditionAvailable) != metav1.ConditionTrue || cond(conds, v1alpha1.ConditionProgressing) != metav1.ConditionFalse || cond(conds, v1alpha1.ConditionDegraded) != metav1.ConditionFalse {
		t.Fatalf("conditions = %+v", conds)
	}
	if meta.FindStatusCondition(conds, v1alpha1.ConditionAvailable).ObservedGeneration != 3 {
		t.Fatal("observedGeneration not propagated")
	}
}

func TestSummarizeProgressingComponent(t *testing.T) {
	conds := summarize(nil, []v1alpha1.ComponentStatus{{Name: "a", Phase: v1alpha1.ComponentPhaseAvailable}, {Name: "b", Phase: v1alpha1.ComponentPhaseProgressing}}, nil, 1)
	if cond(conds, v1alpha1.ConditionProgressing) != metav1.ConditionTrue || cond(conds, v1alpha1.ConditionAvailable) != metav1.ConditionFalse {
		t.Fatalf("conditions = %+v", conds)
	}
}

func TestSummarizeDegradedOnErrorOrDegradedComponent(t *testing.T) {
	conds := summarize(nil, []v1alpha1.ComponentStatus{{Name: "a", Phase: v1alpha1.ComponentPhaseAvailable}}, errors.New("boom"), 1)
	if cond(conds, v1alpha1.ConditionDegraded) != metav1.ConditionTrue || cond(conds, v1alpha1.ConditionAvailable) != metav1.ConditionFalse {
		t.Fatalf("conditions = %+v", conds)
	}
	conds = summarize(nil, []v1alpha1.ComponentStatus{{Name: "a", Phase: v1alpha1.ComponentPhaseDegraded}}, nil, 1)
	if cond(conds, v1alpha1.ConditionDegraded) != metav1.ConditionTrue {
		t.Fatalf("conditions = %+v", conds)
	}
}

func TestSummarizeDisableIncompleteIsAvailableButFlagged(t *testing.T) {
	conds := summarize(nil, []v1alpha1.ComponentStatus{{Name: "snr", Phase: v1alpha1.ComponentPhaseDisableIncomplete}}, nil, 1)
	if cond(conds, v1alpha1.ConditionAvailable) != metav1.ConditionTrue || cond(conds, v1alpha1.ConditionDegraded) != metav1.ConditionFalse {
		t.Fatalf("conditions = %+v", conds)
	}
	if meta.FindStatusCondition(conds, v1alpha1.ConditionAvailable).Reason != "DisableIncomplete" {
		t.Fatalf("reason = %q", meta.FindStatusCondition(conds, v1alpha1.ConditionAvailable).Reason)
	}
}

func TestSummarizeKeepsTransitionTimeWhenUnchanged(t *testing.T) {
	disabled := []v1alpha1.ComponentStatus{{Name: "a", Phase: v1alpha1.ComponentPhaseDisabled}}
	first := summarize(nil, disabled, nil, 1)
	old := metav1.NewTime(metav1.Now().Add(-time.Hour))
	for i := range first {
		first[i].LastTransitionTime = old
	}
	second := summarize(first, disabled, nil, 1)
	for _, c := range second {
		if !c.LastTransitionTime.Equal(&old) {
			t.Fatalf("%s lastTransitionTime changed although its status did not", c.Type)
		}
	}
	third := summarize(second, []v1alpha1.ComponentStatus{{Name: "a", Phase: v1alpha1.ComponentPhaseProgressing}}, nil, 2)
	if meta.FindStatusCondition(third, v1alpha1.ConditionProgressing).LastTransitionTime.Equal(&old) {
		t.Fatal("Progressing changed status but kept its old lastTransitionTime")
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/controller/ -run TestSummarize`
Expected: `undefined: summarize`.

- [ ] **Step 3: Implement `status.go`**

```go
// internal/controller/status.go
package controller

import (
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
)

// summarize derives the three top-level conditions from component statuses, starting from the
// existing conditions so an unchanged condition keeps its lastTransitionTime. That keeps repeated
// reconciles from rewriting status, which would otherwise retrigger the controller in a loop.
// Available=True means WAO reconciled successfully and no enabled component is still
// progressing or degraded; it does not claim that workloads are protected.
func summarize(existing []metav1.Condition, components []v1alpha1.ComponentStatus, reconcileErr error, generation int64) []metav1.Condition {
	progressing, degraded, incomplete := false, reconcileErr != nil, false
	for _, c := range components {
		switch c.Phase {
		case v1alpha1.ComponentPhaseProgressing:
			progressing = true
		case v1alpha1.ComponentPhaseDegraded:
			degraded = true
		case v1alpha1.ComponentPhaseDisableIncomplete:
			incomplete = true
		}
	}
	set := func(conds *[]metav1.Condition, t string, status metav1.ConditionStatus, reason, msg string) {
		meta.SetStatusCondition(conds, metav1.Condition{Type: t, Status: status, Reason: reason, Message: msg, ObservedGeneration: generation})
	}
	conds := append([]metav1.Condition(nil), existing...)
	switch {
	case degraded:
		msg := "one or more components failed to reconcile"
		if reconcileErr != nil {
			msg = reconcileErr.Error()
		}
		set(&conds, v1alpha1.ConditionDegraded, metav1.ConditionTrue, "ReconcileError", msg)
	default:
		set(&conds, v1alpha1.ConditionDegraded, metav1.ConditionFalse, "AsExpected", "")
	}
	if progressing {
		set(&conds, v1alpha1.ConditionProgressing, metav1.ConditionTrue, "ComponentsProgressing", "operand rollout or admission readiness pending")
	} else {
		set(&conds, v1alpha1.ConditionProgressing, metav1.ConditionFalse, "AsExpected", "")
	}
	switch {
	case degraded:
		set(&conds, v1alpha1.ConditionAvailable, metav1.ConditionFalse, "Degraded", "see Degraded condition")
	case progressing:
		set(&conds, v1alpha1.ConditionAvailable, metav1.ConditionFalse, "Progressing", "see Progressing condition")
	case incomplete:
		set(&conds, v1alpha1.ConditionAvailable, metav1.ConditionTrue, "DisableIncomplete", "a disabled component still has retained agents or configs; see status.components")
	default:
		set(&conds, v1alpha1.ConditionAvailable, metav1.ConditionTrue, "AsExpected", "")
	}
	return conds
}
```

- [ ] **Step 4: Run the status tests**

Run: `go test ./internal/controller/ -run TestSummarize -v`
Expected: PASS.

- [ ] **Step 5: Write the failing envtest specs**

Replace the scaffolded `suite_test.go` with this version. It loads every CRD from
`config/crd/bases`, creates namespace `wao-test` and runs the reconciler in a real
manager:

```go
// internal/controller/suite_test.go
package controller

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

var (
	k8sClient client.Client
	testEnv   *envtest.Environment
	cancel    context.CancelFunc
)

func testImages() images.Set {
	s := images.Set{}
	for _, k := range images.Required {
		s[k] = "example.test/" + strings.ToLower(k) + "@sha256:0000000000000000000000000000000000000000000000000000000000000000"
	}
	return s
}

func TestControllers(t *testing.T) {
	RegisterFailHandler(Fail)
	SetDefaultEventuallyTimeout(20 * time.Second)
	RunSpecs(t, "Controller Suite")
}

var _ = BeforeSuite(func() {
	var ctx context.Context
	ctx, cancel = context.WithCancel(context.Background())
	testEnv = &envtest.Environment{CRDDirectoryPaths: []string{filepath.Join("..", "..", "config", "crd", "bases")}, ErrorIfCRDPathMissing: true}
	cfg, err := testEnv.Start()
	Expect(err).NotTo(HaveOccurred())
	Expect(v1alpha1.AddToScheme(scheme.Scheme)).To(Succeed())
	k8sClient, err = client.New(cfg, client.Options{Scheme: scheme.Scheme})
	Expect(err).NotTo(HaveOccurred())
	Expect(k8sClient.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}})).To(Succeed())
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme.Scheme, Metrics: metricsserver.Options{BindAddress: "0"}})
	Expect(err).NotTo(HaveOccurred())
	Expect((&WorkloadAvailabilityConfigReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Namespace: ns, Images: testImages()}).SetupWithManager(mgr)).To(Succeed())
	go func() { defer GinkgoRecover(); Expect(mgr.Start(ctx)).To(Succeed()) }()
})

var _ = AfterSuite(func() {
	cancel()
	Expect(testEnv.Stop()).To(Succeed())
})
```

Replace the scaffolded controller test with the following Ginkgo specs:

```go
// internal/controller/workloadavailabilityconfig_controller_test.go
package controller

import (
	"context"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
	"github.com/jwmatthews/wao_poc/internal/operands"
)

const ns = "wao-test"

func getWAC(ctx context.Context) *v1alpha1.WorkloadAvailabilityConfig {
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	Expect(k8sClient.Get(ctx, types.NamespacedName{Name: v1alpha1.SingletonName}, w)).To(Succeed())
	return w
}

func component(w *v1alpha1.WorkloadAvailabilityConfig, key string) *v1alpha1.ComponentStatus {
	for i := range w.Status.Components {
		if w.Status.Components[i].Name == key {
			return &w.Status.Components[i]
		}
	}
	return nil
}

func setState(ctx context.Context, key string, state v1alpha1.ComponentState) {
	Eventually(func() error {
		w := getWAC(ctx)
		switch key {
		case v1alpha1.ComponentKeyNodeHealthCheck:
			w.Spec.Components.NodeHealthCheck.State = state
		case v1alpha1.ComponentKeySelfNodeRemediation:
			w.Spec.Components.SelfNodeRemediation.State = state
		case v1alpha1.ComponentKeyStorageBasedRemediation:
			w.Spec.Components.StorageBasedRemediation.State = state
		case v1alpha1.ComponentKeyFenceAgentsRemediation:
			w.Spec.Components.FenceAgentsRemediation.State = state
		case v1alpha1.ComponentKeyMachineDeletionRemediation:
			w.Spec.Components.MachineDeletionRemediation.State = state
		case v1alpha1.ComponentKeyNodeMaintenance:
			w.Spec.Components.NodeMaintenance.State = state
		}
		return k8sClient.Update(ctx, w)
	}).Should(Succeed())
}

var _ = Describe("WorkloadAvailabilityConfig controller", Ordered, func() {
	ctx := context.Background()

	It("rejects a non-singleton name via CEL", func() {
		bad := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: "other"}}
		err := k8sClient.Create(ctx, bad)
		Expect(apierrors.IsInvalid(err)).To(BeTrue(), "got %v", err)
		Expect(err.Error()).To(ContainSubstring("singleton"))
	})

	It("reports Available with every component Disabled and creates nothing", func() {
		Expect(k8sClient.Create(ctx, &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}})).To(Succeed())
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			g.Expect(meta.IsStatusConditionTrue(w.Status.Conditions, v1alpha1.ConditionAvailable)).To(BeTrue())
			g.Expect(w.Status.Components).To(HaveLen(6))
			for _, c := range w.Status.Components {
				g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			}
			g.Expect(w.Status.InstallNamespace).To(Equal(ns))
			g.Expect(w.Status.ReleaseSet).To(HaveLen(len(images.Required)))
			g.Expect(w.Finalizers).To(ContainElement(Finalizer))
		}).Should(Succeed())
		deps := &appsv1.DeploymentList{}
		Expect(k8sClient.List(ctx, deps, client.InNamespace(ns))).To(Succeed())
		Expect(deps.Items).To(BeEmpty())
	})

	It("does not rewrite status when nothing changes", func() {
		rv := getWAC(ctx).ResourceVersion
		Consistently(func() string { return getWAC(ctx).ResourceVersion }, 5*time.Second, 250*time.Millisecond).Should(Equal(rv))
	})

	It("installs the NHC operand when enabled", func() {
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateEnabled)
		// Status is written after every operand object has been applied, so wait for it first.
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c).NotTo(BeNil())
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseProgressing)) // envtest has no kubelet or service-ca
			g.Expect(c.Deployments).To(HaveLen(1))
			g.Expect(c.AdmissionReady).To(Equal(ptr.To(false)))
		}).Should(Succeed())
		dep := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, dep)).To(Succeed())
		Expect(dep.Spec.Template.Spec.Containers[0].Image).To(Equal(testImages().Get(images.NHCManager)))
		Expect(dep.Labels[operands.LabelManagedBy]).To(Equal(operands.ManagedByValue))
		Expect(dep.OwnerReferences).To(HaveLen(1))
		Expect(dep.OwnerReferences[0].Kind).To(Equal("WorkloadAvailabilityConfig"))
		Expect(*dep.OwnerReferences[0].Controller).To(BeTrue())

		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{})).To(Succeed())
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &corev1.ServiceAccount{})).To(Succeed())
		vw := &admissionregistrationv1.ValidatingWebhookConfiguration{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-validating-webhook-configuration"}, vw)).To(Succeed())
		Expect(vw.Webhooks[0].ClientConfig.Service.Namespace).To(Equal(ns))
		Expect(vw.Annotations["service.beta.openshift.io/inject-cabundle"]).To(Equal("true"))
	})

	It("refuses to adopt a foreign object with the same name", func() {
		foreign := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "sbr-operator-controller-manager", Namespace: ns},
			Spec: appsv1.DeploymentSpec{Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "foreign"}},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "foreign"}},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "x", Image: "example.test/foreign"}}}}}}
		Expect(k8sClient.Create(ctx, foreign)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			c := component(w, v1alpha1.ComponentKeyStorageBasedRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDegraded))
			g.Expect(c.Message).To(ContainSubstring("not managed by"))
			g.Expect(meta.IsStatusConditionTrue(w.Status.Conditions, v1alpha1.ConditionDegraded)).To(BeTrue())
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed())
		Expect(foreign.Spec.Template.Spec.Containers[0].Image).To(Equal("example.test/foreign"))
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyStorageBasedRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			g.Expect(c.Message).To(ContainSubstring("foreign"))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed(), "WAO must not delete a foreign object on disable")
		Expect(k8sClient.Delete(ctx, foreign)).To(Succeed()) // test cleanup, not WAO behavior
	})

	It("removes the NHC operand and reports admission unavailable when disabled", func() {
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateDisabled)
		// Status is written after every operand object has been deleted, so wait for it first.
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			g.Expect(c.AdmissionReady).To(Equal(ptr.To(false)))
			g.Expect(c.Message).To(ContainSubstring("admission"))
		}).Should(Succeed())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-validating-webhook-configuration"}, &admissionregistrationv1.ValidatingWebhookConfiguration{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{}))).To(BeTrue())
	})

	It("reports DisableIncomplete when SNR agents survive a manager-level disable", func() {
		// Simulate what the SNR manager creates at runtime. Do it while SNR is Disabled: once enabled,
		// SNR's Fail-policy webhooks are registered and envtest has no backend to answer them.
		cfg := &unstructured.Unstructured{}
		cfg.SetGroupVersionKind(schema.GroupVersionKind{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediationConfig"})
		cfg.SetName("self-node-remediation-config")
		cfg.SetNamespace(ns)
		Expect(k8sClient.Create(ctx, cfg)).To(Succeed())
		ds := &appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: "self-node-remediation-ds", Namespace: ns,
			OwnerReferences: []metav1.OwnerReference{{APIVersion: "self-node-remediation.medik8s.io/v1alpha1", Kind: "SelfNodeRemediationConfig", Name: cfg.GetName(), UID: cfg.GetUID(), Controller: ptr.To(true)}}},
			Spec: appsv1.DaemonSetSpec{Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "snr-agent"}},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "snr-agent"}},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "agent", Image: "example.test/agent"}}}}}}
		Expect(k8sClient.Create(ctx, ds)).To(Succeed())

		setState(ctx, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeySelfNodeRemediation).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "self-node-remediation-controller-manager"}, &appsv1.Deployment{})).To(Succeed())

		setState(ctx, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			c := component(w, v1alpha1.ComponentKeySelfNodeRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisableIncomplete))
			g.Expect(strings.Join(c.RetainedResources, "\n")).To(ContainSubstring("DaemonSet " + ns + "/self-node-remediation-ds"))
			g.Expect(strings.Join(c.RetainedResources, "\n")).To(ContainSubstring("SelfNodeRemediationConfig " + ns + "/self-node-remediation-config"))
			g.Expect(meta.FindStatusCondition(w.Status.Conditions, v1alpha1.ConditionAvailable).Reason).To(Equal("DisableIncomplete"))
		}).Should(Succeed())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "self-node-remediation-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ds), ds)).To(Succeed(), "WAO must not delete the agent DaemonSet")
		Expect(k8sClient.Delete(ctx, ds)).To(Succeed())
		Expect(k8sClient.Delete(ctx, cfg)).To(Succeed())
	})

	It("installs FAR, MDR and NMO with component-isolated selectors", func() {
		for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
			setState(ctx, key, v1alpha1.ComponentStateEnabled)
		}
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
				g.Expect(component(w, key).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing), key)
			}
		}).Should(Succeed())
		for _, name := range []string{"fence-agents-remediation-controller-manager", "machine-deletion-remediation-controller-manager", "node-maintenance-operator-controller-manager"} {
			Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &appsv1.Deployment{})).To(Succeed(), name)
		}
		svc := &corev1.Service{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "machine-deletion-remediation-controller-manager-metrics-service"}, svc)).To(Succeed())
		Expect(svc.Spec.Selector).To(HaveKeyWithValue("workloadavailability.medik8s.io/component", v1alpha1.ComponentKeyMachineDeletionRemediation))
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "fence-agents-remediation-mutating-webhook-configuration"}, &admissionregistrationv1.MutatingWebhookConfiguration{})).To(Succeed())
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-maintenance-operator-validating-webhook-configuration"}, &admissionregistrationv1.ValidatingWebhookConfiguration{})).To(Succeed())
		for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
			setState(ctx, key, v1alpha1.ComponentStateDisabled)
		}
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
				g.Expect(component(w, key).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled), key)
			}
		}).Should(Succeed())
	})

	It("reports a NodeMaintenance left behind by a disabled NMO as retained", func() {
		// Created while NMO is Disabled: its Fail-policy webhook would otherwise need a backend.
		nm := &unstructured.Unstructured{}
		nm.SetGroupVersionKind(schema.GroupVersionKind{Group: "nodemaintenance.medik8s.io", Version: "v1beta1", Kind: "NodeMaintenance"})
		nm.SetName("wao-test-maintenance")
		Expect(unstructured.SetNestedField(nm.Object, "wao-test-node", "spec", "nodeName")).To(Succeed())
		Expect(unstructured.SetNestedField(nm.Object, "envtest", "spec", "reason")).To(Succeed())
		Expect(k8sClient.Create(ctx, nm)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeMaintenance, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing))
		}).Should(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeMaintenance, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisableIncomplete))
			g.Expect(c.RetainedResources).To(ContainElement("nodemaintenance.medik8s.io/v1beta1 NodeMaintenance wao-test-maintenance"))
		}).Should(Succeed())
		Expect(k8sClient.Delete(ctx, nm)).To(Succeed())
		Eventually(func(g Gomega) { // picked up by the periodic re-check
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
		}, 90*time.Second, time.Second).Should(Succeed())
	})

	It("runs the disable sequence and drops its finalizer on deletion", func() {
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func() error {
			return k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "sbr-operator-controller-manager"}, &appsv1.Deployment{})
		}).Should(Succeed())
		Expect(k8sClient.Delete(ctx, getWAC(ctx))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: v1alpha1.SingletonName}, &v1alpha1.WorkloadAvailabilityConfig{}))
		}).Should(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "sbr-operator-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue(), "explicit deletion; envtest has no garbage collector")
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "sbr-operator-sbr-agent-role"}, &rbacv1.ClusterRole{}))).To(BeTrue())
	})
})
```

Two of these specs guard behaviors that are easy to break silently:
- "does not rewrite status when nothing changes" fails when `summarize` rebuilds conditions instead of starting from the existing ones.
- "reports a NodeMaintenance left behind by a disabled NMO as retained" exercises `ManagedKinds` and the periodic re-check. The re-check is needed because WAO does not watch component objects.

envtest runs a real API server but no webhook backends. While a component with
`Fail` webhooks is Enabled, creating or updating its native objects in envtest fails
with "failed calling webhook". The specs therefore create native objects only while
the component is Disabled.

- [ ] **Step 6: Run the suite to verify it fails**

Run: `make test` (or `go test ./internal/controller/... -v`)
Expected: failures on missing finalizer/status or undefined behavior; compile must
succeed once the reconciler struct has the new fields (add them first if needed).

- [ ] **Step 7: Implement the reconciler**

```go
// internal/controller/workloadavailabilityconfig_controller.go
package controller

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/images"
	"github.com/jwmatthews/wao_poc/internal/operands"
)

const (
	Finalizer          = "workloadavailability.medik8s.io/finalizer"
	FieldOwner         = "workload-availability-operator"
	requeueProgressing = 30 * time.Second
	// Retained objects are not watched; re-check them periodically so status stays current.
	requeueRetained = 60 * time.Second
)

// WorkloadAvailabilityConfigReconciler installs and removes operand components.
type WorkloadAvailabilityConfigReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	Namespace string
	Images    images.Set
}

// RBAC for WAO's own objects. Operand permissions come from config/rbac/operand_union_role.yaml.
// +kubebuilder:rbac:groups=workloadavailability.medik8s.io,resources=workloadavailabilityconfigs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=workloadavailability.medik8s.io,resources=workloadavailabilityconfigs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=workloadavailability.medik8s.io,resources=workloadavailabilityconfigs/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=daemonsets,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=services;serviceaccounts;configmaps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=roles;rolebindings;clusterroles;clusterrolebindings,verbs=get;list;watch;create;update;patch;delete;bind
// +kubebuilder:rbac:groups=admissionregistration.k8s.io,resources=validatingwebhookconfigurations;mutatingwebhookconfigurations,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=self-node-remediation.medik8s.io,resources=selfnoderemediationconfigs;selfnoderemediations,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage-based-remediation.medik8s.io,resources=storagebasedremediationconfigs;storagebasedremediations,verbs=get;list;watch
// +kubebuilder:rbac:groups=remediation.medik8s.io,resources=nodehealthchecks,verbs=get;list;watch
// +kubebuilder:rbac:groups=fence-agents-remediation.medik8s.io,resources=fenceagentsremediations,verbs=get;list;watch
// +kubebuilder:rbac:groups=machine-deletion-remediation.medik8s.io,resources=machinedeletionremediations,verbs=get;list;watch
// +kubebuilder:rbac:groups=nodemaintenance.medik8s.io,resources=nodemaintenances,verbs=get;list;watch

func (r *WorkloadAvailabilityConfigReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	wac := &v1alpha1.WorkloadAvailabilityConfig{}
	if err := r.Get(ctx, req.NamespacedName, wac); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if wac.Name != v1alpha1.SingletonName {
		log.Info("ignoring non-singleton WorkloadAvailabilityConfig", "name", wac.Name)
		return ctrl.Result{}, nil
	}
	if !wac.DeletionTimestamp.IsZero() {
		return r.finalize(ctx, wac)
	}
	if controllerutil.AddFinalizer(wac, Finalizer) {
		return ctrl.Result{Requeue: true}, r.Update(ctx, wac)
	}

	var statuses []v1alpha1.ComponentStatus
	var errs []error
	progressing, retained := false, false
	for _, def := range components.All() {
		var st v1alpha1.ComponentStatus
		var err error
		if wac.Spec.StateOf(def.Key) == v1alpha1.ComponentStateEnabled {
			st, err = r.ensureEnabled(ctx, wac, def)
		} else {
			st, err = r.ensureDisabled(ctx, def)
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", def.Key, err))
			st.Name, st.DesiredState = def.Key, wac.Spec.StateOf(def.Key)
			st.Phase, st.Message = v1alpha1.ComponentPhaseDegraded, err.Error()
		}
		if st.Phase == v1alpha1.ComponentPhaseProgressing {
			progressing = true
		}
		if st.Phase == v1alpha1.ComponentPhaseDisableIncomplete {
			retained = true
		}
		statuses = append(statuses, st)
	}
	joined := errors.Join(errs...)
	wac.Status.ObservedGeneration = wac.Generation
	wac.Status.InstallNamespace = r.Namespace
	wac.Status.Components = statuses
	wac.Status.ReleaseSet = nil
	for _, k := range r.Images.Sorted() {
		wac.Status.ReleaseSet = append(wac.Status.ReleaseSet, v1alpha1.ImageReference{Name: k, Image: r.Images.Get(k)})
	}
	wac.Status.Conditions = summarize(wac.Status.Conditions, statuses, joined, wac.Generation)
	if err := r.Status().Update(ctx, wac); err != nil {
		return ctrl.Result{}, err
	}
	if joined != nil {
		return ctrl.Result{}, joined
	}
	if progressing {
		return ctrl.Result{RequeueAfter: requeueProgressing}, nil
	}
	if retained {
		return ctrl.Result{RequeueAfter: requeueRetained}, nil
	}
	return ctrl.Result{}, nil
}

func (r *WorkloadAvailabilityConfigReconciler) ensureEnabled(ctx context.Context, wac *v1alpha1.WorkloadAvailabilityConfig, def components.Definition) (v1alpha1.ComponentStatus, error) {
	st := v1alpha1.ComponentStatus{Name: def.Key, DesiredState: v1alpha1.ComponentStateEnabled}
	objs, err := operands.Render(def, r.Namespace, r.Images)
	if err != nil {
		return st, err
	}
	for _, o := range objs {
		if err := r.guardForeign(ctx, o); err != nil {
			return st, err
		}
		o.SetOwnerReferences([]metav1.OwnerReference{{APIVersion: v1alpha1.GroupVersion.String(), Kind: "WorkloadAvailabilityConfig",
			Name: wac.Name, UID: wac.UID, Controller: ptr.To(true), BlockOwnerDeletion: ptr.To(true)}})
		o.SetManagedFields(nil)
		if err := r.Patch(ctx, o, client.Apply, client.FieldOwner(FieldOwner), client.ForceOwnership); err != nil {
			return st, fmt.Errorf("apply %s/%s: %w", o.GetKind(), o.GetName(), err)
		}
	}
	ready := true
	for _, name := range def.Deployments {
		dep := &appsv1.Deployment{}
		if err := r.Get(ctx, types.NamespacedName{Namespace: r.Namespace, Name: name}, dep); err != nil {
			return st, err
		}
		ds := v1alpha1.DeploymentStatus{Name: name, DesiredReplicas: ptr.Deref(dep.Spec.Replicas, 1), ReadyReplicas: dep.Status.ReadyReplicas}
		ds.Ready = dep.Status.ObservedGeneration >= dep.Generation && ds.ReadyReplicas == ds.DesiredReplicas && dep.Status.UpdatedReplicas == ds.DesiredReplicas
		ready = ready && ds.Ready
		st.Deployments = append(st.Deployments, ds)
	}
	if len(def.Webhooks) > 0 {
		ok, err := r.admissionReady(ctx, def)
		if err != nil {
			return st, err
		}
		st.AdmissionReady = &ok
		ready = ready && ok
	}
	if ready {
		st.Phase = v1alpha1.ComponentPhaseAvailable
	} else {
		st.Phase = v1alpha1.ComponentPhaseProgressing
		st.Message = "waiting for operand Deployments and admission certificates"
	}
	return st, nil
}

// guardForeign refuses to take over an existing object that WAO did not create.
func (r *WorkloadAvailabilityConfigReconciler) guardForeign(ctx context.Context, desired *unstructured.Unstructured) error {
	existing := &unstructured.Unstructured{}
	existing.SetGroupVersionKind(desired.GroupVersionKind())
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if existing.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue {
		return fmt.Errorf("%s %s/%s exists and is not managed by %s; refusing to adopt it", desired.GetKind(), desired.GetNamespace(), desired.GetName(), operands.ManagedByValue)
	}
	return nil
}

func (r *WorkloadAvailabilityConfigReconciler) admissionReady(ctx context.Context, def components.Definition) (bool, error) {
	for _, w := range def.Webhooks {
		switch w.Kind {
		case "ValidatingWebhookConfiguration":
			cfg := &admissionregistrationv1.ValidatingWebhookConfiguration{}
			if err := r.Get(ctx, types.NamespacedName{Name: w.Name}, cfg); err != nil {
				return false, client.IgnoreNotFound(err)
			}
			for _, h := range cfg.Webhooks {
				if len(h.ClientConfig.CABundle) == 0 {
					return false, nil
				}
			}
		case "MutatingWebhookConfiguration":
			cfg := &admissionregistrationv1.MutatingWebhookConfiguration{}
			if err := r.Get(ctx, types.NamespacedName{Name: w.Name}, cfg); err != nil {
				return false, client.IgnoreNotFound(err)
			}
			for _, h := range cfg.Webhooks {
				if len(h.ClientConfig.CABundle) == 0 {
					return false, nil
				}
			}
		default:
			return false, fmt.Errorf("unknown webhook kind %q", w.Kind)
		}
	}
	return true, nil
}

func (r *WorkloadAvailabilityConfigReconciler) ensureDisabled(ctx context.Context, def components.Definition) (v1alpha1.ComponentStatus, error) {
	st := v1alpha1.ComponentStatus{Name: def.Key, DesiredState: v1alpha1.ComponentStateDisabled, Phase: v1alpha1.ComponentPhaseDisabled}
	objs, err := operands.Render(def, r.Namespace, r.Images)
	if err != nil {
		return st, err
	}
	var skipped []string
	for i := len(objs) - 1; i >= 0; i-- { // webhooks first, service accounts last
		o := objs[i]
		existing := &unstructured.Unstructured{}
		existing.SetGroupVersionKind(o.GroupVersionKind())
		err := r.Get(ctx, client.ObjectKeyFromObject(o), existing)
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			return st, err
		}
		if existing.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue {
			skipped = append(skipped, fmt.Sprintf("%s %s/%s", o.GetKind(), o.GetNamespace(), o.GetName()))
			continue
		}
		if err := r.Delete(ctx, existing); err != nil && !apierrors.IsNotFound(err) {
			return st, fmt.Errorf("delete %s/%s: %w", o.GetKind(), o.GetName(), err)
		}
	}
	retained, err := r.retainedResources(ctx, def)
	if err != nil {
		return st, err
	}
	st.RetainedResources = retained
	var msgs []string
	if len(retained) > 0 {
		st.Phase = v1alpha1.ComponentPhaseDisableIncomplete
		msgs = append(msgs, "manager removed; agents, configs or native objects it would reconcile remain and need the component's own procedure")
	}
	if len(skipped) > 0 {
		msgs = append(msgs, fmt.Sprintf("left foreign objects untouched: %v", skipped))
	}
	if len(def.Webhooks) > 0 {
		st.AdmissionReady = ptr.To(false)
		msgs = append(msgs, "admission for this component's APIs is unavailable while Disabled")
	}
	if len(msgs) > 0 {
		st.Message = fmt.Sprint(msgs)
	}
	return st, nil
}

// retainedResources lists what outlives a manager-level disable: agent DaemonSets owned by
// component configs and those configs (install namespace), plus native objects of the
// component's managed kinds anywhere in the cluster.
func (r *WorkloadAvailabilityConfigReconciler) retainedResources(ctx context.Context, def components.Definition) ([]string, error) {
	var out []string
	if len(def.AgentOwners) > 0 {
		kinds := map[string]bool{}
		for _, a := range def.AgentOwners {
			kinds[a.Kind] = true
		}
		dsl := &appsv1.DaemonSetList{}
		if err := r.List(ctx, dsl, client.InNamespace(r.Namespace)); err != nil {
			return nil, err
		}
		for _, ds := range dsl.Items {
			for _, ref := range ds.OwnerReferences {
				if kinds[ref.Kind] {
					out = append(out, fmt.Sprintf("apps/v1 DaemonSet %s/%s", ds.Namespace, ds.Name))
					break
				}
			}
		}
	}
	list := func(k components.ResourceKind, opts ...client.ListOption) error {
		l := &unstructured.UnstructuredList{}
		l.SetGroupVersionKind(schema.GroupVersionKind{Group: k.Group, Version: k.Version, Kind: k.Kind + "List"})
		if err := r.List(ctx, l, opts...); err != nil {
			if apierrors.IsNotFound(err) || meta.IsNoMatchError(err) { // CRD absent: nothing retained
				return nil
			}
			return err
		}
		for _, item := range l.Items {
			name := item.GetName()
			if item.GetNamespace() != "" {
				name = item.GetNamespace() + "/" + name
			}
			out = append(out, fmt.Sprintf("%s/%s %s %s", k.Group, k.Version, k.Kind, name))
		}
		return nil
	}
	for _, a := range def.AgentOwners {
		if err := list(a, client.InNamespace(r.Namespace)); err != nil {
			return nil, err
		}
	}
	for _, m := range def.ManagedKinds {
		if err := list(m); err != nil {
			return nil, err
		}
	}
	sort.Strings(out)
	return out, nil
}

func (r *WorkloadAvailabilityConfigReconciler) finalize(ctx context.Context, wac *v1alpha1.WorkloadAvailabilityConfig) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(wac, Finalizer) {
		return ctrl.Result{}, nil
	}
	log := logf.FromContext(ctx)
	for _, def := range components.All() {
		st, err := r.ensureDisabled(ctx, def)
		if err != nil {
			return ctrl.Result{}, err
		}
		if len(st.RetainedResources) > 0 {
			log.Info("config deleted with retained component resources", "component", def.Key, "retained", st.RetainedResources)
		}
	}
	controllerutil.RemoveFinalizer(wac, Finalizer)
	return ctrl.Result{}, r.Update(ctx, wac)
}

// SetupWithManager registers the controller.
func (r *WorkloadAvailabilityConfigReconciler) SetupWithManager(mgr ctrl.Manager) error {
	toSingleton := handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, _ client.Object) []reconcile.Request {
		return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: v1alpha1.SingletonName}}}
	})
	inNamespace := predicate.NewPredicateFuncs(func(o client.Object) bool { return o.GetNamespace() == r.Namespace })
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1alpha1.WorkloadAvailabilityConfig{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&admissionregistrationv1.ValidatingWebhookConfiguration{}).
		Owns(&admissionregistrationv1.MutatingWebhookConfiguration{}).
		Watches(&appsv1.DaemonSet{}, toSingleton, builder.WithPredicates(inNamespace)).
		Named("workloadavailabilityconfig").
		Complete(r)
}
```

- [ ] **Step 8: Run the full suite**

Run: `make test`
Expected: all specs PASS. Known pitfalls: `Owns` on cluster-scoped webhook kinds
requires the owner reference to be set (it is); `UnstructuredList` listing of
component configs needs the component CRDs installed in envtest (they are, from
`config/crd/bases`).

- [ ] **Step 9: Commit**

```sh
git add -A && git commit -m "wao: reconcile component operands from WorkloadAvailabilityConfig with foreign-object guard and retained-agent reporting"
```

### Task 6: Manager wiring, default config bootstrap, deployment manifest

**Files:**
- Modify: `cmd/main.go`
- Create: `internal/controller/bootstrap.go`, `internal/controller/bootstrap_test.go`
- Modify: `config/manager/manager.yaml`, `config/default/kustomization.yaml`,
  `config/rbac/kustomization.yaml`, `Makefile`, `Dockerfile`

**Interfaces:**
- Produces: `func EnsureDefaultConfig(ctx context.Context, c client.Client) error` creating
  `WorkloadAvailabilityConfig/cluster` with an empty spec when absent (D4); env
  contract for the WAO Deployment: `OPERATOR_NAMESPACE` (downward API) and the seven
  `RELATED_IMAGE_*` variables; Make variables `IMG`, `PLATFORM ?= linux/amd64`.

- [ ] **Step 1: Write the failing bootstrap test (fake client)**

```go
// internal/controller/bootstrap_test.go
package controller

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
)

func TestEnsureDefaultConfigCreatesDisabledSingleton(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = v1alpha1.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	if err := EnsureDefaultConfig(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	if err := c.Get(context.Background(), types.NamespacedName{Name: v1alpha1.SingletonName}, w); err != nil {
		t.Fatal(err)
	}
	for _, k := range v1alpha1.AllComponentKeys {
		if w.Spec.StateOf(k) != v1alpha1.ComponentStateDisabled {
			t.Fatalf("%s not Disabled", k)
		}
	}
}

func TestEnsureDefaultConfigLeavesExistingUntouched(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = v1alpha1.AddToScheme(scheme)
	existing := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}}
	existing.Spec.Components.NodeHealthCheck.State = v1alpha1.ComponentStateEnabled
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existing).Build()
	if err := EnsureDefaultConfig(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	_ = c.Get(context.Background(), types.NamespacedName{Name: v1alpha1.SingletonName}, w)
	if w.Spec.StateOf(v1alpha1.ComponentKeyNodeHealthCheck) != v1alpha1.ComponentStateEnabled {
		t.Fatal("existing spec was modified")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/controller/ -run TestEnsureDefaultConfig`
Expected: `undefined: EnsureDefaultConfig`.

- [ ] **Step 3: Implement bootstrap and wire `main.go`**

```go
// internal/controller/bootstrap.go
package controller

import (
	"context"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
)

// EnsureDefaultConfig creates the all-Disabled singleton when it does not exist (D4).
// It never modifies an existing object.
func EnsureDefaultConfig(ctx context.Context, c client.Client) error {
	w := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}}
	err := c.Create(ctx, w)
	if apierrors.IsAlreadyExists(err) {
		return nil
	}
	return err
}
```

In `cmd/main.go`, add imports for `appsv1 "k8s.io/api/apps/v1"`, `corev1 "k8s.io/api/core/v1"`,
`"sigs.k8s.io/controller-runtime/pkg/cache"`, `"sigs.k8s.io/controller-runtime/pkg/manager"`,
`"github.com/jwmatthews/wao_poc/internal/images"` and the
`internal/controller` package. Then, after flag parsing and before `ctrl.NewManager`:

```go
	imgs, err := images.FromEnv(os.LookupEnv)
	if err != nil {
		setupLog.Error(err, "operand images are not configured")
		os.Exit(1)
	}
	operatorNamespace := os.Getenv("OPERATOR_NAMESPACE")
	if operatorNamespace == "" {
		setupLog.Error(nil, "OPERATOR_NAMESPACE must be set (downward API)")
		os.Exit(1)
	}
```

Restrict the cache to the install namespace for namespaced operand kinds by adding to
`ctrl.Options`:

```go
		Cache: cache.Options{ByObject: map[client.Object]cache.ByObject{
			&appsv1.Deployment{}: {Namespaces: map[string]cache.Config{operatorNamespace: {}}},
			&appsv1.DaemonSet{}:  {Namespaces: map[string]cache.Config{operatorNamespace: {}}},
			&corev1.Service{}:    {Namespaces: map[string]cache.Config{operatorNamespace: {}}},
		}},
```

Replace the scaffolded reconciler setup with:

```go
	if err = (&controller.WorkloadAvailabilityConfigReconciler{
		Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Namespace: operatorNamespace, Images: imgs,
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "WorkloadAvailabilityConfig")
		os.Exit(1)
	}
	if err = mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		select {
		case <-mgr.Elected():
			return controller.EnsureDefaultConfig(ctx, mgr.GetClient())
		case <-ctx.Done():
			return nil
		}
	})); err != nil {
		setupLog.Error(err, "unable to add default config bootstrap")
		os.Exit(1)
	}
```

- [ ] **Step 4: Update the manager Deployment and kustomize**

These values must equal the `pinned` references in `release-set.yaml`; Task 7's bundle check enforces it.

In `config/manager/manager.yaml`, set container args to
`--leader-elect --health-probe-bind-address=:8081 --metrics-bind-address=0` and add:

```yaml
        env:
        - name: OPERATOR_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: RELATED_IMAGE_NHC_MANAGER
          value: quay.io/medik8s/node-healthcheck-operator@sha256:5b048ad5d2b8578d2120989a5a822a041d65c985f9ac88d50b000427b32b5391
        - name: RELATED_IMAGE_SNR_MANAGER
          value: quay.io/medik8s/self-node-remediation-operator@sha256:9ad002dca9ea183c72e350f72e47aff7020397fd476b4a3ac4ebc3627412a5b0
        - name: RELATED_IMAGE_SBR_MANAGER
          value: quay.io/medik8s/storage-based-remediation-operator@sha256:c390b6b011458985823829049afd47f4a85b90cbc020d8527803cce58da8bd04
        - name: RELATED_IMAGE_SBR_AGENT
          value: quay.io/medik8s/storage-based-remediation-agent@sha256:c9fba79e070fdcb5595994d4daab5051c54088bd7565a34b2d19775016db6421
        - name: RELATED_IMAGE_FAR_MANAGER
          value: quay.io/medik8s/fence-agents-remediation-operator@sha256:fab0089a9d656a21c8d0a43622ebe0d6b64a6a76e586d6cb4a06f5ce21c0b583
        - name: RELATED_IMAGE_MDR_MANAGER
          value: quay.io/medik8s/machine-deletion-remediation-operator@sha256:0f69367097625d7824d9b5b69de64103e19b612c9833b0b786bb32c9b7efe84d
        - name: RELATED_IMAGE_NMO_MANAGER
          value: quay.io/medik8s/node-maintenance-operator@sha256:5b65ec62c58b92fee3389a77ded760ce82a0a6a30f6cf89573f6e97b8f677c74
```

Set `namespace: openshift-workload-availability` in `config/default/kustomization.yaml`
and comment out `metrics_service.yaml` plus any `cert-manager`/`network-policy`
resources so the bundle contains only the CSV and CRDs (D6). In
`config/rbac/kustomization.yaml` remove `metrics_auth_role.yaml`,
`metrics_auth_role_binding.yaml` and `metrics_reader_role.yaml`.

In the `Makefile`: add `PLATFORM ?= linux/amd64` and change `docker-build` to
`$(CONTAINER_TOOL) build --platform $(PLATFORM) -t $(IMG) .`. Confirm the scaffolded
`Dockerfile` builds with `GOARCH=$${TARGETARCH}`; the cluster is amd64 and the
workstation is arm64.

- [ ] **Step 5: Run all tests and a local manager smoke start**

Run: `make generate manifests test`
Expected: PASS. Then verify startup validation without a cluster:

```sh
OPERATOR_NAMESPACE=x go run ./cmd 2>&1 | head -3
```

Expected: exits non-zero with `operand images are not configured` naming the seven variables.

- [ ] **Step 6: Commit**

```sh
git add -A && git commit -m "wao: wire manager, image env contract, namespace-scoped cache and default config bootstrap"
```

### Task 7: CSV base and bundle

**Files:**
- Create: `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml`
- Create: `hack/check-bundle.py`
- Create (generated, committed): `bundle/**`, `bundle.Dockerfile`
- Modify: `Makefile` (`bundle-check` target)

**Interfaces:**
- Consumes: `release-set.yaml`, `config/manager/manager.yaml` (Task 6), the CRDs (Task 3).
- Produces: package `workload-availability-operator`, CSV `workload-availability-operator.v0.1.0`, channel `alpha`; the CSV owns exactly thirteen CRDs; `relatedImages` lists the seven pinned operand images; install mode `AllNamespaces` only.

- [ ] **Step 1: Write the bundle check**

```python
#!/usr/bin/env python3
# hack/check-bundle.py
"""Assert the generated bundle matches the POC contract and release-set.yaml. Exit 1 with reasons."""
import pathlib, sys

import yaml

EXPECTED_CRDS = {
    "workloadavailabilityconfigs.workloadavailability.medik8s.io",
    "nodehealthchecks.remediation.medik8s.io",
    "selfnoderemediationconfigs.self-node-remediation.medik8s.io",
    "selfnoderemediations.self-node-remediation.medik8s.io",
    "selfnoderemediationtemplates.self-node-remediation.medik8s.io",
    "storagebasedremediationconfigs.storage-based-remediation.medik8s.io",
    "storagebasedremediations.storage-based-remediation.medik8s.io",
    "storagebasedremediationtemplates.storage-based-remediation.medik8s.io",
    "fenceagentsremediations.fence-agents-remediation.medik8s.io",
    "fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io",
    "machinedeletionremediations.machine-deletion-remediation.medik8s.io",
    "machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io",
    "nodemaintenances.nodemaintenance.medik8s.io",
}


def pinned_images(release_set_path):
    rs = yaml.safe_load(pathlib.Path(release_set_path).read_text())
    return {env: img["pinned"] for comp in rs["components"].values() for env, img in comp["images"].items()}


def main(bundle_dir="bundle", release_set="release-set.yaml"):
    pinned = pinned_images(release_set)
    problems, csv, crds, extra = [], None, set(), []
    for f in sorted(pathlib.Path(bundle_dir, "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csv = obj
        elif obj["kind"] == "CustomResourceDefinition":
            crds.add(obj["metadata"]["name"])
        else:
            extra.append(f"{obj['kind']}/{obj['metadata']['name']}")
    if csv is None:
        sys.exit("no CSV in bundle")
    spec = csv["spec"]
    owned = {c["name"] for c in spec["customresourcedefinitions"].get("owned", [])}
    if owned != EXPECTED_CRDS:
        problems.append(f"owned CRDs differ: missing={sorted(EXPECTED_CRDS - owned)} unexpected={sorted(owned - EXPECTED_CRDS)}")
    if crds != EXPECTED_CRDS:
        problems.append(f"bundle CRD files differ: missing={sorted(EXPECTED_CRDS - crds)} unexpected={sorted(crds - EXPECTED_CRDS)}")
    related = {ri["image"] for ri in spec.get("relatedImages", []) or []}
    if not set(pinned.values()) <= related:
        problems.append(f"relatedImages missing pinned images: {sorted(set(pinned.values()) - related)}")
    modes = {m["type"]: m["supported"] for m in spec["installModes"]}
    if modes != {"OwnNamespace": False, "SingleNamespace": False, "MultiNamespace": False, "AllNamespaces": True}:
        problems.append(f"installModes = {modes}")
    deployments = spec["install"]["spec"]["deployments"]
    if len(deployments) != 1:
        problems.append(f"CSV must deploy only the WAO controller, got {[d['name'] for d in deployments]}")
    else:
        container = deployments[0]["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e.get("value") for e in container.get("env", [])}
        for name, image in pinned.items():
            if env.get(name) != image:
                problems.append(f"WAO Deployment env {name}={env.get(name)!r}, release-set.yaml pins {image!r}")
        if "OPERATOR_NAMESPACE" not in env:
            problems.append("WAO Deployment lacks OPERATOR_NAMESPACE")
    if csv["metadata"]["annotations"].get("operatorframework.io/suggested-namespace") != "openshift-workload-availability":
        problems.append("suggested-namespace annotation missing or wrong")
    if extra:
        problems.append(f"bundle contains objects a ConfigMap catalog cannot carry: {extra}")
    if problems:
        print("\n".join(problems)); sys.exit(1)
    print(f"bundle OK: {csv['metadata']['name']} owns {len(owned)} CRDs, {len(pinned)} pinned operand images")


if __name__ == "__main__":
    main(*sys.argv[1:])
```

Add to the `Makefile`:

```make
.PHONY: bundle-check
bundle-check:
	$(PYTHON) hack/check-bundle.py bundle release-set.yaml
```

- [ ] **Step 2: Generate a first bundle and watch the check fail**

```sh
operator-sdk generate kustomize manifests --interactive=false
make bundle IMG=quay.io/example/workload-availability-operator:dev VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check
```

Expected: FAIL, listing at least missing owned CRDs, missing related images, wrong install modes and the suggested-namespace annotation.

- [ ] **Step 3: Author the CSV base**

Write `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml`:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: ClusterServiceVersion
metadata:
  name: workload-availability-operator.v0.0.0
  namespace: placeholder
  annotations:
    alm-examples: |-
      [
        {
          "apiVersion": "workloadavailability.medik8s.io/v1alpha1",
          "kind": "WorkloadAvailabilityConfig",
          "metadata": {"name": "cluster"},
          "spec": {"components": {"nodeHealthCheck": {"state": "Disabled"}, "selfNodeRemediation": {"state": "Disabled"}, "storageBasedRemediation": {"state": "Disabled"}}}
        }
      ]
    capabilities: Basic Install
    categories: OpenShift Optional
    description: Proof of concept single operator that installs the six medik8s workload availability operators (NHC, SNR, SBR, FAR, MDR, NMO) as managed operands.
    operatorframework.io/suggested-namespace: openshift-workload-availability
    operatorframework.io/suggested-namespace-template: '{"kind":"Namespace","apiVersion":"v1","metadata":{"name":"openshift-workload-availability","annotations":{"openshift.io/node-selector":""}}}'
    repository: https://github.com/jwmatthews/wao_poc
    support: Proof of concept, unsupported
spec:
  displayName: Workload Availability Operator (POC)
  description: |
    Proof of concept. One package owning the NHC, SNR, SBR, FAR, MDR and NMO APIs plus a
    cluster-scoped WorkloadAvailabilityConfig. Component operators run unchanged from their
    upstream images.
    Every component is Disabled after installation. Enabling selfNodeRemediation starts node
    agents exactly as a standalone SNR installation does.
  keywords: [remediation, node, availability, medik8s]
  maturity: alpha
  provider:
    name: wao_poc
  installModes:
  - type: OwnNamespace
    supported: false
  - type: SingleNamespace
    supported: false
  - type: MultiNamespace
    supported: false
  - type: AllNamespaces
    supported: true
  relatedImages:
  - name: nhc-manager
    image: quay.io/medik8s/node-healthcheck-operator@sha256:5b048ad5d2b8578d2120989a5a822a041d65c985f9ac88d50b000427b32b5391
  - name: snr-manager
    image: quay.io/medik8s/self-node-remediation-operator@sha256:9ad002dca9ea183c72e350f72e47aff7020397fd476b4a3ac4ebc3627412a5b0
  - name: sbr-manager
    image: quay.io/medik8s/storage-based-remediation-operator@sha256:c390b6b011458985823829049afd47f4a85b90cbc020d8527803cce58da8bd04
  - name: sbr-agent
    image: quay.io/medik8s/storage-based-remediation-agent@sha256:c9fba79e070fdcb5595994d4daab5051c54088bd7565a34b2d19775016db6421
  - name: far-manager
    image: quay.io/medik8s/fence-agents-remediation-operator@sha256:fab0089a9d656a21c8d0a43622ebe0d6b64a6a76e586d6cb4a06f5ce21c0b583
  - name: mdr-manager
    image: quay.io/medik8s/machine-deletion-remediation-operator@sha256:0f69367097625d7824d9b5b69de64103e19b612c9833b0b786bb32c9b7efe84d
  - name: nmo-manager
    image: quay.io/medik8s/node-maintenance-operator@sha256:5b65ec62c58b92fee3389a77ded760ce82a0a6a30f6cf89573f6e97b8f677c74
  customresourcedefinitions:
    owned:
    - name: workloadavailabilityconfigs.workloadavailability.medik8s.io
      kind: WorkloadAvailabilityConfig
      version: v1alpha1
      displayName: Workload Availability Config
      description: Singleton installation intent and status for the workload availability components.
    - name: nodehealthchecks.remediation.medik8s.io
      kind: NodeHealthCheck
      version: v1alpha1
      displayName: Node Health Check
      description: Owned by WAO; served by the NHC operand when enabled.
    - name: selfnoderemediationconfigs.self-node-remediation.medik8s.io
      kind: SelfNodeRemediationConfig
      version: v1alpha1
      displayName: Self Node Remediation Config
      description: Owned by WAO; served by the SNR operand when enabled.
    - name: selfnoderemediations.self-node-remediation.medik8s.io
      kind: SelfNodeRemediation
      version: v1alpha1
      displayName: Self Node Remediation
      description: Owned by WAO; served by the SNR operand when enabled.
    - name: selfnoderemediationtemplates.self-node-remediation.medik8s.io
      kind: SelfNodeRemediationTemplate
      version: v1alpha1
      displayName: Self Node Remediation Template
      description: Owned by WAO; served by the SNR operand when enabled.
    - name: storagebasedremediationconfigs.storage-based-remediation.medik8s.io
      kind: StorageBasedRemediationConfig
      version: v1alpha1
      displayName: Storage Based Remediation Config
      description: Owned by WAO; served by the SBR operand when enabled.
    - name: storagebasedremediations.storage-based-remediation.medik8s.io
      kind: StorageBasedRemediation
      version: v1alpha1
      displayName: Storage Based Remediation
      description: Owned by WAO; served by the SBR operand when enabled.
    - name: storagebasedremediationtemplates.storage-based-remediation.medik8s.io
      kind: StorageBasedRemediationTemplate
      version: v1alpha1
      displayName: Storage Based Remediation Template
      description: Owned by WAO; served by the SBR operand when enabled.
    - name: fenceagentsremediations.fence-agents-remediation.medik8s.io
      kind: FenceAgentsRemediation
      version: v1alpha1
      displayName: Fence Agents Remediation
      description: Owned by WAO; served by the FAR operand when enabled.
    - name: fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io
      kind: FenceAgentsRemediationTemplate
      version: v1alpha1
      displayName: Fence Agents Remediation Template
      description: Owned by WAO; served by the FAR operand when enabled.
    - name: machinedeletionremediations.machine-deletion-remediation.medik8s.io
      kind: MachineDeletionRemediation
      version: v1alpha1
      displayName: Machine Deletion Remediation
      description: Owned by WAO; served by the MDR operand when enabled.
    - name: machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io
      kind: MachineDeletionRemediationTemplate
      version: v1alpha1
      displayName: Machine Deletion Remediation Template
      description: Owned by WAO; served by the MDR operand when enabled.
    - name: nodemaintenances.nodemaintenance.medik8s.io
      kind: NodeMaintenance
      version: v1beta1
      displayName: Node Maintenance
      description: Owned by WAO; served by the NMO operand when enabled.
  install:
    spec:
      deployments: null
    strategy: ""
  version: 0.0.0
```

The upstream NHC CSV advertises no console plugin, so this CSV does not either.

- [ ] **Step 4: Regenerate the bundle and validate**

```sh
make bundle IMG=quay.io/example/workload-availability-operator:dev VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check
operator-sdk bundle validate ./bundle --select-optional suite=operatorframework
```

Expected: `bundle OK: workload-availability-operator.v0.1.0 owns 13 CRDs, 7 pinned operand images`, and `All validation tests have completed successfully`.

If `bundle-check` reports extra objects, remove them from the `config/default` or `config/rbac` kustomizations. OLM folds the WAO service account's roles into the CSV automatically. If `relatedImages` disappears after generation, check that the base file name matches the package name exactly.

- [ ] **Step 5: Commit**

```sh
git add -A && git commit -m "wao: author CSV base and generate the POC bundle owning thirteen CRDs"
```

### Task 8: Operator image and POC catalog

**Files:**
- Create: `hack/configmap-catalog.py`, `hack/configmap_catalog_test.py`
- Modify: `Makefile` (`catalog-configmap` target), `README.md`

**Interfaces:**
- Consumes: `bundle/` from Task 7.
- Produces: `hack/configmap-catalog.py --bundle bundle --package workload-availability-operator --channel alpha --name wao-poc-catalog --namespace openshift-marketplace`
  printing a two-document YAML (ConfigMap with keys `customResourceDefinitions`,
  `clusterServiceVersions`, `packages`; CatalogSource `sourceType: internal`).

- [ ] **Step 1: Write the failing catalog test**

```python
# hack/configmap_catalog_test.py
import json, pathlib, subprocess, sys, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = HERE.parent / "bundle"


class CatalogTest(unittest.TestCase):
    def setUp(self):
        if not BUNDLE.exists():
            self.skipTest("bundle not generated")
        out = subprocess.run([sys.executable, str(HERE / "configmap-catalog.py"), "--bundle", str(BUNDLE),
                              "--package", "workload-availability-operator", "--channel", "alpha",
                              "--name", "wao-poc-catalog", "--namespace", "openshift-marketplace"],
                             check=True, capture_output=True, text=True).stdout
        self.docs = list(yaml.safe_load_all(out))

    def test_configmap_and_catalogsource(self):
        cm = next(d for d in self.docs if d["kind"] == "ConfigMap")
        cs = next(d for d in self.docs if d["kind"] == "CatalogSource")
        self.assertEqual(cm["metadata"]["namespace"], "openshift-marketplace")
        self.assertEqual(cs["spec"], {"sourceType": "internal", "configMap": "wao-poc-catalog",
                                      "displayName": "WAO POC catalog", "publisher": "wao_poc"})
        crds = json.loads(cm["data"]["customResourceDefinitions"])
        csvs = json.loads(cm["data"]["clusterServiceVersions"])
        pkgs = json.loads(cm["data"]["packages"])
        self.assertEqual(len(crds), 8)
        self.assertEqual(len(csvs), 1)
        self.assertEqual(pkgs, [{"packageName": "workload-availability-operator", "defaultChannel": "alpha",
                                 "channels": [{"name": "alpha", "currentCSV": csvs[0]["metadata"]["name"]}]}])
        self.assertLess(sum(len(v) for v in cm["data"].values()), 900 * 1024, "ConfigMap size budget")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `.venv/bin/python -m unittest hack/configmap_catalog_test.py -v`
Expected: `FileNotFoundError` (script missing).

- [ ] **Step 3: Write the catalog script**

```python
#!/usr/bin/env python3
"""Render a ConfigMap-backed OLM CatalogSource from a registry+v1 bundle directory (POC only, D6)."""
import argparse, json, pathlib, sys
import yaml


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--package", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--namespace", default="openshift-marketplace")
    a = ap.parse_args()
    crds, csvs, extra = [], [], []
    for f in sorted(pathlib.Path(a.bundle, "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        {"CustomResourceDefinition": crds, "ClusterServiceVersion": csvs}.get(obj["kind"], extra).append(obj)
    if len(csvs) != 1:
        sys.exit(f"expected one CSV, found {len(csvs)}")
    if extra:
        sys.exit("ConfigMap catalogs carry only CRDs and CSVs; remove: " + ", ".join(f"{o['kind']}/{o['metadata']['name']}" for o in extra))
    data = {"customResourceDefinitions": json.dumps(crds, sort_keys=True),
            "clusterServiceVersions": json.dumps(csvs, sort_keys=True),
            "packages": json.dumps([{"packageName": a.package, "defaultChannel": a.channel,
                                     "channels": [{"name": a.channel, "currentCSV": csvs[0]["metadata"]["name"]}]}])}
    size = sum(len(v) for v in data.values())
    if size > 900 * 1024:
        sys.exit(f"catalog data {size} bytes exceeds the ConfigMap budget")
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": a.name, "namespace": a.namespace}, "data": data}
    cs = {"apiVersion": "operators.coreos.com/v1alpha1", "kind": "CatalogSource",
          "metadata": {"name": a.name, "namespace": a.namespace},
          "spec": {"sourceType": "internal", "configMap": a.name, "displayName": "WAO POC catalog", "publisher": "wao_poc"}}
    print("---\n".join(yaml.safe_dump(x, sort_keys=False, width=4096) for x in (cm, cs)), end="")


if __name__ == "__main__":
    main()
```

Add to the `Makefile`:

```make
CATALOG_NS ?= openshift-marketplace
.PHONY: catalog-configmap
catalog-configmap: bundle-check
	mkdir -p dist
	$(PYTHON) hack/configmap-catalog.py --bundle bundle --package workload-availability-operator --channel $(DEFAULT_CHANNEL) --name wao-poc-catalog --namespace $(CATALOG_NS) > dist/wao-poc-catalog.yaml
```

- [ ] **Step 4: Run the test**

Run: `.venv/bin/python -m unittest hack/configmap_catalog_test.py -v`
Expected: PASS.

- [ ] **Step 5: Build and publish the WAO image for amd64**

Choose one registry the cluster can pull from and record the choice in `README.md`.

Option A, public Quay repository (needs `podman login quay.io` once):

```sh
export IMG=quay.io/<account>/workload-availability-operator:poc-0.1.0
make docker-build docker-push IMG=$IMG PLATFORM=linux/amd64
```

Option B, OpenShift internal registry (no external credentials; requires the image
registry operator to be available on the cluster):

```sh
K="--kubeconfig $KUBECONFIG"   # a disposable cluster you may modify
oc $K new-project openshift-workload-availability 2>/dev/null || oc $K project openshift-workload-availability
oc $K new-build --binary --name wao -n openshift-workload-availability --strategy docker
oc $K start-build wao -n openshift-workload-availability --from-dir=. --follow
export IMG=image-registry.openshift-image-registry.svc:5000/openshift-workload-availability/wao:latest
```

Then regenerate the bundle with the final image and rebuild the catalog:

```sh
make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check
mkdir -p dist && make catalog-configmap DEFAULT_CHANNEL=alpha
```

Expected: `dist/wao-poc-catalog.yaml` exists; `bundle/manifests/*.clusterserviceversion.yaml`
references `$IMG` in the controller Deployment and in `relatedImages`.

For the later upgrade step an FBC image is required instead; the scaffolded
`make catalog-build catalog-push BUNDLE_IMGS=... CATALOG_IMG=...` targets (they
download `opm`) are the path, not this ConfigMap.

- [ ] **Step 6: Commit**

```sh
git add -A && git commit -m "wao: add ConfigMap catalog renderer and amd64 image build instructions"
```

### Task 9: Live-cluster install verification harness

**Files:**
- Create: `test/cluster/env.sh`, `test/cluster/lib.sh`, `test/cluster/README.md`
- Create: `test/cluster/00-preflight.sh`, `02-install-wao.sh`, `05-enable-nhc.sh`, `07-enable-snr.sh`, `11-enable-far.sh`, `12-enable-mdr.sh`, `13-enable-nmo.sh`, and one script per remaining case in section 4
- Create: `test/cluster/parity.py`, `test/cluster/parity_test.py`
- Modify: `Makefile` (`test-offline` target)

**Interfaces:**
- Consumes: `dist/wao-poc-catalog.yaml` (Task 8), `.cache/bundles/` and `release-set.yaml` (Task 3), `KUBECONFIG`.
- Produces: shell helpers `k`, `record <name> <args…>`, `wait_for <seconds> <description> <command…>`, `expect <description> <command…>`, `component_field <key> <field>` and `snapshot <label>`. Every case script exits non-zero on a failed expectation. Raw output goes to `evidence/<date>-wao-poc/raw/`, which is git-ignored.

- [ ] **Step 1: Write the parity checker's offline test**

`parity.py` compares live Deployments and ClusterRoles with the upstream CSV. This test proves the comparison logic against the extracted manifests, without a cluster:

```python
# test/cluster/parity_test.py — offline checks: extracted operand manifests must be parity-clean.
import copy, importlib.util, pathlib, unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("parity", HERE / "parity.py")
parity = importlib.util.module_from_spec(spec); spec.loader.exec_module(parity)


@unittest.skipUnless((REPO / ".cache/bundles/nhc/fetch.json").exists(), "run `make bundles` first")
class ParityTest(unittest.TestCase):
    def setUp(self):
        self.release_set = yaml.safe_load((REPO / "release-set.yaml").read_text())

    def rendered(self, component, name):
        f = REPO / "internal/operands/manifests" / component / f"50-Deployment-{name}.yaml"
        images = parity.image_map(self.release_set, component)
        return parity.pin(yaml.safe_load(f.read_text()), images)  # what WAO applies

    def test_extracted_deployments_match_bundle(self):
        for comp in ("nhc", "snr", "sbr", "far", "mdr", "nmo"):
            images = parity.image_map(self.release_set, comp)
            for d in parity.bundle_csv(comp)["spec"]["install"]["spec"]["deployments"]:
                live = self.rendered(comp, d["name"])
                self.assertEqual(parity.compare_deployment(d, live["spec"], images), 0, f"{comp}/{d['name']}")

    def test_detects_changed_args(self):
        images = parity.image_map(self.release_set, "snr")
        d = parity.bundle_csv("snr")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("snr", d["name"]))
        live["spec"]["template"]["spec"]["containers"][0]["args"].append("--extra")
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 1)

    def test_detects_unpinned_image(self):
        images = parity.image_map(self.release_set, "nhc")
        d = parity.bundle_csv("nhc")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("nhc", d["name"]))
        live["spec"]["template"]["spec"]["containers"][0]["image"] = "quay.io/medik8s/node-healthcheck-operator:v0.12.0"
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 1)

    def test_ignores_api_server_defaults(self):
        images = parity.image_map(self.release_set, "snr")
        d = parity.bundle_csv("snr")["spec"]["install"]["spec"]["deployments"][0]
        live = copy.deepcopy(self.rendered("snr", d["name"]))
        c = live["spec"]["template"]["spec"]["containers"][0]
        c["livenessProbe"]["timeoutSeconds"] = 1
        c["imagePullPolicy"] = "IfNotPresent"
        for e in c["env"]:
            if "valueFrom" in e:
                e["valueFrom"]["fieldRef"]["apiVersion"] = "v1"
        self.assertEqual(parity.compare_deployment(d, live["spec"], images), 0)


if __name__ == "__main__":
    unittest.main()
```

Run: `.venv/bin/python -m unittest discover -s test/cluster -p 'parity_test.py' -v`
Expected: import error, because `parity.py` does not exist. Use `discover`, because the directory name `test` collides with Python's standard-library `test` package when given as a module path.

- [ ] **Step 2: Write the parity checker**

```python
#!/usr/bin/env python3
# test/cluster/parity.py
"""Compare live operand Deployments and ClusterRoles with the upstream bundle CSV.

Usage: parity.py --component nhc|snr|sbr|far|mdr|nmo [--namespace openshift-workload-availability]
Requires KUBECONFIG. Reads the CSV from .cache/bundles/<component>/manifests and maps
upstream image tags to pinned digests from release-set.yaml before comparing.
Tolerated differences: the WAO-added webhook-server-cert volume and mount (D1), the WAO component
pod label (D10), and
fields the bundle leaves unset that the API server defaults.
Exit 0 when identical, 1 with a unified diff otherwise.
"""
import argparse, difflib, json, os, pathlib, subprocess, sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
WAO_VOLUME = "webhook-server-cert"
CONTAINER_FIELDS = ["image", "command", "args", "env", "ports", "livenessProbe", "readinessProbe", "startupProbe",
                    "securityContext", "resources", "volumeMounts"]


def image_map(release_set, component):
    return {i["upstream"]: i["pinned"] for i in release_set["components"][component]["images"].values()}


def bundle_csv(component):
    for f in sorted((REPO / ".cache/bundles" / component / "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            return obj
    raise SystemExit(f"no CSV for {component}; run `make bundles`")


def pin(obj, images):
    text = json.dumps(obj, sort_keys=True)
    for upstream, pinned in images.items():
        text = text.replace(json.dumps(upstream)[1:-1], json.dumps(pinned)[1:-1])
    return json.loads(text)


def normalize_deployment(spec):
    pod = spec["template"]["spec"]
    containers = []
    for c in pod["containers"]:
        cc = {f: c.get(f) for f in CONTAINER_FIELDS}
        cc["volumeMounts"] = [m for m in c.get("volumeMounts") or [] if m["name"] != WAO_VOLUME] or None
        containers.append(cc)
    return {"replicas": spec.get("replicas", 1), "selector": spec["selector"],
            "serviceAccountName": pod.get("serviceAccountName"), "tolerations": pod.get("tolerations"),
            "priorityClassName": pod.get("priorityClassName"), "securityContext": pod.get("securityContext"),
            "affinity": pod.get("affinity"), "topologySpreadConstraints": pod.get("topologySpreadConstraints"),
            "volumes": [v for v in pod.get("volumes") or [] if v["name"] != WAO_VOLUME] or None,
            "containers": containers}


def project(got, want):
    """Keep only the parts of got that want specifies, so API-server defaults
    (probe timeouts, port protocols, fieldRef apiVersion, ...) are not reported."""
    if isinstance(want, dict) and isinstance(got, dict):
        return {k: project(got.get(k), v) for k, v in want.items()}
    if isinstance(want, list) and isinstance(got, list) and len(want) == len(got):
        return [project(g, w) for g, w in zip(got, want)]
    return got


def diff(label, want, got):
    got = project(got, want)
    a = json.dumps(want, indent=1, sort_keys=True).splitlines()
    b = json.dumps(got, indent=1, sort_keys=True).splitlines()
    if a == b:
        print(f"OK {label}")
        return 0
    print(f"DIFF {label}")
    print("\n".join(difflib.unified_diff(a, b, "bundle", "live", lineterm="")))
    return 1


def compare_deployment(bundle_dep, live_spec, images):
    return diff(f"Deployment/{bundle_dep['name']}", normalize_deployment(pin(bundle_dep["spec"], images)), normalize_deployment(live_spec))


def compare_rules(name, bundle_rules, live_rules):
    key = lambda r: json.dumps(r, sort_keys=True)
    return diff(f"ClusterRole/{name}", sorted(bundle_rules, key=key), sorted(live_rules, key=key))


def kubectl_json(*args):
    kc = os.environ.get("KUBECONFIG")
    if not kc:
        raise SystemExit("KUBECONFIG must be set")
    tool = os.environ.get("OC", "kubectl")
    return json.loads(subprocess.check_output([tool, "--kubeconfig", kc, *args, "-o", "json"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--component", required=True, choices=["nhc", "snr", "sbr", "far", "mdr", "nmo"])
    ap.add_argument("--namespace", default="openshift-workload-availability")
    a = ap.parse_args()
    release_set = yaml.safe_load((REPO / "release-set.yaml").read_text())
    images = image_map(release_set, a.component)
    spec = bundle_csv(a.component)["spec"]["install"]["spec"]
    failures = 0
    for d in spec["deployments"]:
        live = kubectl_json("get", "deployment", d["name"], "-n", a.namespace)
        failures += compare_deployment(d, live["spec"], images)
    for p in spec.get("clusterPermissions") or []:
        live = kubectl_json("get", "clusterrole", p["serviceAccountName"])
        failures += compare_rules(p["serviceAccountName"], p["rules"], live["rules"])
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the offline test**

Run: `.venv/bin/python -m unittest discover -s test/cluster -p 'parity_test.py' -v`
Expected: four tests PASS, covering all six operands. Add a Makefile target that runs every offline Python test:

```make
.PHONY: test-offline
test-offline:
	$(PYTHON) -m unittest hack/extract_operand_manifests_test.py hack/configmap_catalog_test.py
	$(PYTHON) -m unittest discover -s test/cluster -p 'parity_test.py'
```

- [ ] **Step 4: Write the shared environment and library**

```sh
# test/cluster/env.sh
# shellcheck shell=bash
: "${KUBECONFIG:?set KUBECONFIG to a disposable OpenShift cluster you are authorized to modify}"
export KUBECONFIG
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export OC="${OC:-oc}"                                  # oc or kubectl
export NS="${NS:-openshift-workload-availability}"
export CAT_NS="${CAT_NS:-openshift-marketplace}"
export CATALOG="${CATALOG:-wao-poc-catalog}"
export PACKAGE="${PACKAGE:-workload-availability-operator}"
export CHANNEL="${CHANNEL:-alpha}"
export RUN_DIR="${RUN_DIR:-${REPO_ROOT}/evidence/$(date -u +%F)-wao-poc}"   # git-ignored
mkdir -p "${RUN_DIR}/raw"
```

```sh
# test/cluster/lib.sh
# shellcheck shell=bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

k() { "${OC}" --kubeconfig "${KUBECONFIG}" --request-timeout=30s "$@"; }
export -f k   # usable inside `bash -c` subshells

# record NAME ARGS... : run k ARGS, save {command, exit_code, stdout, stderr} as JSON, echo stdout.
record() {
  local name="$1"; shift
  local ts tmpo tmpe code=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; tmpo="$(mktemp)"; tmpe="$(mktemp)"
  k "$@" >"$tmpo" 2>"$tmpe" || code=$?
  python3 - "${RUN_DIR}/raw/${ts}-${name}.json" "$code" "$tmpo" "$tmpe" "$*" <<'PY'
import json, sys
path, code, outf, errf, cmd = sys.argv[1:6]
json.dump({"command": cmd.split(), "exit_code": int(code), "stdout": open(outf).read(), "stderr": open(errf).read()}, open(path, "w"), indent=1)
PY
  cat "$tmpo"; cat "$tmpe" >&2
  rm -f "$tmpo" "$tmpe"
  return $code
}

# wait_for SECONDS DESCRIPTION COMMAND... : poll every 5s until COMMAND succeeds.
wait_for() {
  local limit="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > limit )); then echo "TIMEOUT: $desc" >&2; return 1; fi
    sleep 5
  done
  echo "ok: $desc"
}

# expect DESCRIPTION COMMAND... : fail the case when COMMAND fails.
expect() {
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc" >&2; return 1; fi
}

# component_field KEY FIELD : print one field of a component status entry.
component_field() {
  k get workloadavailabilityconfig cluster -o json | python3 -c '
import json, sys
s = json.load(sys.stdin).get("status", {})
c = [x for x in s.get("components", []) if x["name"] == sys.argv[1]]
v = c[0].get(sys.argv[2]) if c else None
print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"
}
export -f component_field

# snapshot LABEL : persist the objects every case compares.
snapshot() {
  local l="$1"
  record "${l}-csv" get csv -n "$NS" -o json >/dev/null || true
  record "${l}-deploy" get deployment -n "$NS" -o json >/dev/null || true
  record "${l}-ds" get daemonset -n "$NS" -o json >/dev/null || true
  record "${l}-pods" get pods -n "$NS" -o wide >/dev/null || true
  record "${l}-webhooks" get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null || true
  record "${l}-wac" get workloadavailabilityconfig cluster -o json >/dev/null || true
}
```

- [ ] **Step 5: Write the case scripts**

Each script sources `lib.sh`, runs the steps of its row in section 4 using `record`, `wait_for` and `expect`, and ends with `snapshot <id>`. Seven scripts are given in full; write the others from their section 4 rows using the same helpers.

```sh
#!/usr/bin/env bash
# test/cluster/00-preflight.sh — WAO-INST-00: the cluster is suitable and clean. Read-only.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-00 preflight (read-only)"
record 00-clusterversion get clusterversion version -o json >/dev/null
record 00-nodes get nodes -o json >/dev/null
record 00-clusteroperators get clusteroperators >/dev/null
topology=$(k get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
expect "control-plane topology '$topology' is supported by NHC admission" \
  bash -c "echo '$topology' | grep -Eqx 'HighlyAvailable|SingleReplica|HighlyAvailableArbiter|External'"
expect "all nodes are linux/amd64 (the pinned operand images are amd64-only)" \
  bash -c "[ -z \"\$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{\"\\n\"}{end}' | grep -vx amd64)\" ]"
expect "classic OLM is present" k get crd catalogsources.operators.coreos.com -o name
expect "no medik8s CRDs exist (remove standalone medik8s operators and their CRDs first)" \
  bash -c "! k get crd -o name | grep -q 'medik8s.io'"
expect "no standalone medik8s operator CSVs exist" \
  bash -c "! k get csv -A -o name | grep -Eq 'node-healthcheck|self-node-remediation|storage-based-remediation|fence-agents-remediation|machine-deletion-remediation|node-maintenance'"
record 00-machine-api get crd machines.machine.openshift.io -o name >/dev/null || echo "note: Machine API absent; MDR can be installed but cannot act (record in RUN.md)"
expect "namespace $NS does not exist yet" bash -c "! k get namespace $NS"
echo "Preflight passed. Record the cluster version and node count (not names) in ${RUN_DIR}/RUN.md."
```

```sh
#!/usr/bin/env bash
# test/cluster/02-install-wao.sh — WAO-INST-01 and WAO-INST-02: catalog, then OLM install.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-01 catalog"
record 01-apply-catalog apply -f "${REPO_ROOT}/dist/wao-poc-catalog.yaml" >/dev/null
wait_for 180 "catalog READY" bash -c "k get catalogsource $CATALOG -n $CAT_NS -o jsonpath='{.status.connectionState.lastObservedState}' | grep -qx READY"
wait_for 180 "packagemanifest visible" k get packagemanifest "$PACKAGE" -n "$CAT_NS"

echo "== WAO-INST-02 install"
record 02-namespace apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  annotations:
    openshift.io/node-selector: ""
YAML
record 02-operatorgroup apply -f - >/dev/null <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: wao
  namespace: ${NS}
spec: {}
YAML
record 02-subscription apply -f - >/dev/null <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${NS}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: ${CATALOG}
  sourceNamespace: ${CAT_NS}
  installPlanApproval: Manual
YAML
wait_for 180 "InstallPlan created" bash -c "k get subscription $PACKAGE -n $NS -o jsonpath='{.status.installPlanRef.name}' | grep -q ."
ip=$(k get subscription "$PACKAGE" -n "$NS" -o jsonpath='{.status.installPlanRef.name}')
record 02-installplan get installplan "$ip" -n "$NS" -o json >/dev/null
record 02-approve patch installplan "$ip" -n "$NS" --type merge -p '{"spec":{"approved":true}}' >/dev/null
csv=$(k get installplan "$ip" -n "$NS" -o jsonpath='{.spec.clusterServiceVersionNames[0]}')
wait_for 300 "CSV $csv Succeeded" bash -c "k get csv $csv -n $NS -o jsonpath='{.status.phase}' | grep -qx Succeeded"
expect "exactly one Deployment (the WAO controller)" bash -c "[ \"\$(k get deployment -n $NS -o name | wc -l | tr -d ' ')\" = 1 ]"
for crd in workloadavailabilityconfigs.workloadavailability.medik8s.io nodehealthchecks.remediation.medik8s.io \
  selfnoderemediationconfigs.self-node-remediation.medik8s.io selfnoderemediations.self-node-remediation.medik8s.io \
  selfnoderemediationtemplates.self-node-remediation.medik8s.io storagebasedremediationconfigs.storage-based-remediation.medik8s.io \
  storagebasedremediations.storage-based-remediation.medik8s.io storagebasedremediationtemplates.storage-based-remediation.medik8s.io \
  fenceagentsremediations.fence-agents-remediation.medik8s.io fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io \
  machinedeletionremediations.machine-deletion-remediation.medik8s.io machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io \
  nodemaintenances.nodemaintenance.medik8s.io; do
  expect "CRD $crd exists" k get crd "$crd" -o name
done
snapshot 02
```

```sh
#!/usr/bin/env bash
# test/cluster/05-enable-nhc.sh — WAO-INST-05
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-05 enable NHC"
record 05-enable patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"}}}}' >/dev/null
wait_for 300 "NHC manager Available" k wait deployment/node-healthcheck-controller-manager -n "$NS" --for=condition=Available --timeout=10s
wait_for 180 "webhook CA bundle injected" bash -c "k get validatingwebhookconfiguration node-healthcheck-validating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q ."
wait_for 180 "status phase Available" bash -c "[ \"\$(component_field nodeHealthCheck phase)\" = Available ]"
expect "status admissionReady true" bash -c "[ \"\$(component_field nodeHealthCheck admissionReady)\" = true ]"
expect "service-ca created the webhook serving Secret" k get secret node-healthcheck-webhook-server-cert -n "$NS" -o name

# Admission: both minHealthy and maxUnhealthy must be rejected by the webhook (no CRD rule covers it). Dry-run only.
set +e
out=$(k apply --dry-run=server -f - 2>&1 <<'YAML'
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: wao-inst-05-invalid
spec:
  minHealthy: 51%
  maxUnhealthy: 1
  selector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: self-node-remediation-automatic-strategy-template
    namespace: openshift-workload-availability
YAML
); code=$?
set -e
printf '%s\n' "$out" > "${RUN_DIR}/raw/05-admission-invalid.txt"
expect "invalid NHC rejected (dry-run)" test $code -ne 0
expect "rejection came from vnodehealthcheck.kb.io" grep -q "vnodehealthcheck.kb.io" <<<"$out"
expect "rejection names the minHealthy/maxUnhealthy rule" grep -q "cannot be specified at the same time" <<<"$out"

expect "NHC initializer created the aggregation ClusterRole" k get clusterrole node-healthcheck-operator-aggregation -o name
record 05-consoleplugin get consoleplugin node-remediation-console-plugin -o json >/dev/null || echo "note: no ConsolePlugin created"
record 05-servicemonitor get servicemonitor -n "$NS" -o json >/dev/null || echo "note: ServiceMonitor API absent"
expect "no NodeHealthCheck policy exists" bash -c "[ -z \"\$(k get nodehealthcheck -o name)\" ]"
record 05-manager-logs logs deployment/node-healthcheck-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 05
```

```sh
#!/usr/bin/env bash
# test/cluster/07-enable-snr.sh — WAO-INST-07. Starts SNR node agents on every eligible node (design brief D3).
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-07 enable SNR"
record 07-enable patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"selfNodeRemediation":{"state":"Enabled"}}}}' >/dev/null
wait_for 300 "SNR manager Available" k wait deployment/self-node-remediation-controller-manager -n "$NS" --for=condition=Available --timeout=10s
for w in validatingwebhookconfiguration/self-node-remediation-validating-webhook-configuration mutatingwebhookconfiguration/self-node-remediation-mutating-webhook-configuration; do
  wait_for 180 "CA bundles injected in $w" bash -c "[ -z \"\$(k get $w -o jsonpath='{range .webhooks[*]}{.clientConfig.caBundle}{\"|\"}{end}' | tr '|' '\n' | grep -x '')\" ]"
done
wait_for 180 "status phase Available" bash -c "[ \"\$(component_field selfNodeRemediation phase)\" = Available ]"
wait_for 120 "SNR created its default config" k get selfnoderemediationconfig self-node-remediation-config -n "$NS"
wait_for 120 "SNR created its default template" k get selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
wait_for 120 "SNR created its peer certificate Secret" k get secret self-node-remediation-certificates -n "$NS"
wait_for 300 "agent DaemonSet fully ready" bash -c "d=\$(k get ds self-node-remediation-ds -n $NS -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}'); set -- \$d; [ \"\$1\" -gt 0 ] && [ \"\$1\" = \"\$2\" ]"
record 07-ds get daemonset self-node-remediation-ds -n "$NS" -o json >/dev/null

set +e
out=$(k apply --dry-run=server -f - 2>&1 <<YAML
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationConfig
metadata:
  name: second-config
  namespace: ${NS}
spec: {}
YAML
); code=$?
set -e
printf '%s\n' "$out" > "${RUN_DIR}/raw/07-admission-second-config.txt"
expect "second SNR config rejected (dry-run)" test $code -ne 0
expect "rejection came from vselfnoderemediationconfig.kb.io" grep -q "vselfnoderemediationconfig.kb.io" <<<"$out"

ann=$(k create --dry-run=server -o jsonpath='{.metadata.annotations.remediation\.medik8s\.io/multiple-templates-support}' -f - <<YAML
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: wao-inst-07-probe
  namespace: ${NS}
spec:
  template:
    spec: {}
YAML
)
expect "mutating webhook reachable (dry-run template gained multiple-templates annotation)" test "$ann" = "true"
snapshot 07
```

```sh
#!/usr/bin/env bash
# test/cluster/11-enable-far.sh — WAO-INST-11. No fencing: only server dry-run templates.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-11 enable FAR"
record 11-enable patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"fenceAgentsRemediation":{"state":"Enabled"}}}}' >/dev/null
wait_for 300 "FAR manager Available" k wait deployment/fence-agents-remediation-controller-manager -n "$NS" --for=condition=Available --timeout=10s
for w in validatingwebhookconfiguration/fence-agents-remediation-validating-webhook-configuration mutatingwebhookconfiguration/fence-agents-remediation-mutating-webhook-configuration; do
  wait_for 180 "CA bundles injected in $w" bash -c "[ -z \"\$(k get $w -o jsonpath='{range .webhooks[*]}{.clientConfig.caBundle}{\"|\"}{end}' | tr '|' '\n' | grep -x '')\" ]"
done
wait_for 180 "status phase Available" bash -c "[ \"\$(component_field fenceAgentsRemediation phase)\" = Available ]"

# FAR v0.8.0 rejects a template without parameters ("mandatory parameters are missing"), so the template
# carries one node parameter for a node that does not exist. The CRD field names are lower case
# (nodeparameters, sharedparameters); camelCase keys are pruned and the template looks empty.
template() { # template NAME AGENT : print a FenceAgentsRemediationTemplate manifest
  cat <<YAML
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  name: $1
  namespace: ${NS}
spec:
  template:
    spec:
      agent: $2
      nodeparameters:
        --plug:
          wao-node-that-does-not-exist: "1"
YAML
}
set +e
out=$(template wao-inst-11-bad fence_wao_does_not_exist | k create --dry-run=server -f - 2>&1); code=$?
set -e
printf '%s\n' "$out" > "${RUN_DIR}/raw/11-admission-unknown-agent.txt"
expect "unknown fence agent rejected (dry-run)" test $code -ne 0
expect "rejection names the unsupported agent" grep -q "unsupported fence agent" <<<"$out"
ann=$(template wao-inst-11-ok fence_ipmilan | k create --dry-run=server -o jsonpath='{.metadata.annotations.remediation\.medik8s\.io/multiple-templates-support}' -f -)
expect "mutating webhook reachable (dry-run template gained multiple-templates annotation)" test "$ann" = "true"
expect "no FenceAgentsRemediation objects exist" bash -c "[ -z \"\$(k get fenceagentsremediations -A -o name)\" ]"
snapshot 11
```

```sh
#!/usr/bin/env bash
# test/cluster/12-enable-mdr.sh — WAO-INST-12. Verifies the shared-namespace selector isolation (design brief D10).
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-12 enable MDR"
record 12-machine-api get crd machines.machine.openshift.io -o name >/dev/null || echo "note: Machine API absent; MDR cannot act on this cluster"
record 12-enable patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"machineDeletionRemediation":{"state":"Enabled"}}}}' >/dev/null
wait_for 300 "MDR manager Available" k wait deployment/machine-deletion-remediation-controller-manager -n "$NS" --for=condition=Available --timeout=10s
wait_for 180 "status phase Available" bash -c "[ \"\$(component_field machineDeletionRemediation phase)\" = Available ]"
svc=machine-deletion-remediation-controller-manager-metrics-service
expect "MDR metrics Service selector carries the component label" \
  bash -c "[ \"\$(k get service $svc -n $NS -o jsonpath='{.spec.selector.workloadavailability\.medik8s\.io/component}')\" = machineDeletionRemediation ]"
record 12-endpointslices get endpointslices -n "$NS" -l kubernetes.io/service-name=$svc -o json >/dev/null
mdr_pods=$(k get pods -n "$NS" -l workloadavailability.medik8s.io/component=machineDeletionRemediation -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
ep_pods=$(k get endpointslices -n "$NS" -l kubernetes.io/service-name=$svc -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}' | sort)
expect "MDR metrics endpoints are exactly the MDR pods" test -n "$ep_pods" -a "$ep_pods" = "$mdr_pods"
snapshot 12
```

```sh
#!/usr/bin/env bash
# test/cluster/13-enable-nmo.sh — WAO-INST-13. Never creates a real NodeMaintenance (that would drain a node).
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-13 enable NMO"
record 13-enable patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"nodeMaintenance":{"state":"Enabled"}}}}' >/dev/null
wait_for 300 "NMO manager Available" k wait deployment/node-maintenance-operator-controller-manager -n "$NS" --for=condition=Available --timeout=10s
wait_for 180 "webhook CA bundle injected" bash -c "k get validatingwebhookconfiguration node-maintenance-operator-validating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q ."
wait_for 180 "status phase Available" bash -c "[ \"\$(component_field nodeMaintenance phase)\" = Available ]"
set +e
out=$(k create --dry-run=server -f - 2>&1 <<'YAML'
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: wao-inst-13-probe
spec:
  nodeName: wao-node-that-does-not-exist
  reason: WAO-INST-13 admission probe (dry-run only)
YAML
); code=$?
set -e
printf '%s\n' "$out" > "${RUN_DIR}/raw/13-admission-missing-node.txt"
expect "NodeMaintenance for a missing node rejected (dry-run)" test $code -ne 0
expect "rejection came from vnodemaintenance.kb.io" grep -q "vnodemaintenance.kb.io" <<<"$out"
expect "rejection names the missing node" grep -q "no node with name wao-node-that-does-not-exist" <<<"$out"
expect "no NodeMaintenance objects exist" bash -c "[ -z \"\$(k get nodemaintenances -o name)\" ]"
record 13-lease-namespace get namespace medik8s-leases -o json >/dev/null || echo "note: medik8s-leases not created yet (created on first node lease)"
snapshot 13
```

- [ ] **Step 6: Verify the helpers without a cluster**

A stub `oc` exercises the helpers offline:

```sh
mkdir -p /tmp/wao-stub && printf '#!/bin/sh\nshift 3\nif [ "$1" = fail ]; then echo boom >&2; exit 3; fi\necho "args:$*"\n' > /tmp/wao-stub/oc && chmod +x /tmp/wao-stub/oc
KUBECONFIG=/dev/null OC=/tmp/wao-stub/oc RUN_DIR=/tmp/wao-stub/run bash -c '
source test/cluster/lib.sh
[ "$(record t-ok get nodes)" = "args:get nodes" ] && echo "record ok"
record t-fail fail 2>/dev/null || echo "failure propagated"
wait_for 6 "k usable in subshells" bash -c "k get x | grep -q args:get"'
bash -n test/cluster/*.sh
```

Expected: `record ok`, `failure propagated`, `ok: k usable in subshells`, and two JSON files under `/tmp/wao-stub/run/raw/`.

- [ ] **Step 7: Write `test/cluster/README.md`**

Explain the prerequisites from section 4, the run order, that `evidence/` holds raw output and is never committed, and how to write the sanitized `results.json` and `REPORT.md`. The sanitized files contain no API URLs, node names, IP addresses, UIDs or Secret data.

- [ ] **Step 8: Commit**

```sh
git add -A && git commit -m "wao: add live-cluster install verification harness and parity checker"
```

### Task 10: Documentation

**Files:**
- Modify: `README.md`, `AGENTS.md`, `docs/operands.md` (only if facts changed)

- [ ] **Step 1: Update `README.md`**

Update the status table. Add the toolchain versions, the generated manifest count, the build and test commands (`make bundles operand-manifests-check generate manifests test test-offline`), image publishing, catalog creation and the install steps. Explain what `Disabled` does and does not do (D2, D5). Give the uninstall order: disable components, delete the config, delete the Subscription and CSV, then remove CRDs and retained SNR objects if desired.

- [ ] **Step 2: Check documentation against the code**

Every object name in `docs/operands.md` must match `internal/operands/manifests/`. Every decision number used in code comments must exist in `docs/design-brief.md`.

- [ ] **Step 3: Commit**

```sh
git add -A && git commit -m "wao: document POC usage"
```

---

## 4. Live-cluster verification: install case

Run from the repository root after Tasks 1–9, with `KUBECONFIG` pointing at the test cluster. Each case `WAO-INST-NN` has a script `test/cluster/NN-<slug>.sh`; see `test/cluster/README.md` for the list. The script listings in Task 9 predate this numbering and the stricter checks; the scripts in `test/cluster/` are authoritative.

Superseded in part by [docs/superpowers/plans/2026-10-10-olmv1-default-deployment.md](superpowers/plans/2026-10-10-olmv1-default-deployment.md) (decisions D11 and D12): cases WAO-INST-00, 01, 02 and 18 now use OLM v1. 01 applies a `ClusterCatalog` instead of the CatalogSource, 02 applies the namespace, installer RBAC and a `ClusterExtension` instead of the OperatorGroup, Subscription and InstallPlan, and 18 deletes the `ClusterExtension`, which removes the thirteen CRDs itself. The rows below for those four cases describe the original classic OLM harness and are kept as history. Cases 03–17 are unchanged.

**Prerequisites:**
- A disposable OpenShift 4.x cluster with classic OLM that you are authorized to modify.
- `linux/amd64` nodes.
- A control-plane topology NHC supports.
- No medik8s operators or CRDs installed.
- The WAO image pullable by the cluster.

MDR additionally needs the OpenShift Machine API to do anything useful. Its manager installs either way, and preflight records whether the API is present.

Raw output goes only to the git-ignored `evidence/`. Before the run, create `evidence/<date>-wao-poc/RUN.md` listing the intended mutations and cleanup.

| ID | Case | Steps | Pass criteria |
| --- | --- | --- | --- |
| WAO-INST-00 | Preflight (`00-preflight.sh`) | Read-only checks | Supported topology; amd64 nodes; OLM present; no `medik8s.io` CRDs; no medik8s operator CSVs; install namespace absent; Machine API presence recorded |
| WAO-INST-01 | Catalog (`01-catalog.sh`) | Apply `dist/wao-poc-catalog.yaml` | CatalogSource `READY` within 180 s; packagemanifest `workload-availability-operator` lists channel `alpha` |
| WAO-INST-02 | Install via OLM (`02-install-wao.sh`) | Namespace with `openshift.io/node-selector: ""`; OperatorGroup with empty spec; Subscription with `installPlanApproval: Manual`; approve the InstallPlan | CSV `workload-availability-operator.v0.1.0` `Succeeded` within 300 s; exactly one Deployment in the namespace; all thirteen CRDs present |
| WAO-INST-03 | Clean-install invariants | Inspect namespace and cluster | No operand Deployment, DaemonSet or Service; no object of any of the twelve component kinds anywhere; no `*.kb.io` webhook configurations; no PVC in the namespace; no `medik8s-leases` namespace created by WAO |
| WAO-INST-04 | Default config, status and CEL | `get wac cluster -o yaml`; try creating a config named `other` | Config exists without administrator action (D4); six component entries, all `Disabled`; `Available=True` reason `AsExpected`; `Progressing=False`; `Degraded=False`; `releaseSet` equals the seven pinned images; the `other` config is rejected with the singleton message |
| WAO-INST-05 | Enable NHC (`05-enable-nhc.sh`) | Patch `nodeHealthCheck.state: Enabled` | Manager Available; serving Secret `node-healthcheck-webhook-server-cert` created by service-ca; CA bundle injected; status `Available` with `admissionReady: true`; dry-run NHC with both `minHealthy` and `maxUnhealthy` rejected by `vnodehealthcheck.kb.io` with "cannot be specified at the same time"; aggregation ClusterRole created by NHC; no NHC policy exists. Record whether `ConsolePlugin` and `ServiceMonitor` were created; the upstream bundle ships no console-plugin backend |
| WAO-INST-06 | Enable SNR (`06-enable-snr.sh`) | Patch `selfNodeRemediation.state: Enabled` | Manager Available; all four webhooks carry CA bundles; status `Available`; SNR itself creates `self-node-remediation-config`, `self-node-remediation-automatic-strategy-template` and Secret `self-node-remediation-certificates`; DaemonSet `self-node-remediation-ds` ready on every scheduled node; dry-run config `second-config` rejected by `vselfnoderemediationconfig.kb.io`; dry-run template returns annotation `remediation.medik8s.io/multiple-templates-support: "true"` |
| WAO-INST-07 | Enable SBR (`07-enable-sbr.sh`) | Patch `storageBasedRemediation.state: Enabled` | Manager Available; ServiceAccount `sbr-operator-sbr-agent`; ClusterRoleBinding `sbr-operator-sbr-agent-rolebinding` subject namespace is `openshift-workload-availability`; no DaemonSet, PVC or Job; status `Available` with no `admissionReady` field; dry-run `StorageBasedRemediationConfig` create succeeds and is not applied for real |
| WAO-INST-08 | Enable FAR (`08-enable-far.sh`) | Patch `fenceAgentsRemediation.state: Enabled` | Manager Available; all four FAR webhooks carry CA bundles; status `Available`; the manager ServiceAccount can list and watch Secrets in all namespaces (OLM all-namespaces copy of the CSV `permissions`) and its log has no "secrets is forbidden" error; dry-run template (with one `nodeparameters` entry for a nonexistent node) with agent `fence_wao_does_not_exist` rejected with "unsupported fence agent"; dry-run template with agent `fence_ipmilan` returns the multiple-templates annotation; no `FenceAgentsRemediation` exists |
| WAO-INST-09 | Enable MDR (`09-enable-mdr.sh`) | Patch `machineDeletionRemediation.state: Enabled` | Manager Available; status `Available` with no `admissionReady` field; metrics Service selector carries `workloadavailability.medik8s.io/component=machineDeletionRemediation`; its EndpointSlices contain exactly the MDR pods, although five other `control-plane: controller-manager` managers run in the namespace (D10) |
| WAO-INST-10 | Enable NMO (`10-enable-nmo.sh`) | Patch `nodeMaintenance.state: Enabled` | Manager Available; CA bundle injected; status `Available`; dry-run `NodeMaintenance` for `wao-node-that-does-not-exist` rejected by `vnodemaintenance.kb.io` with "no node with name"; no `NodeMaintenance` exists. The NMO manager ServiceAccount can list and watch namespaces cluster-wide (OLM's namespaces rule on the all-namespaces ClusterRole); `medik8s-leases` exists within 120 s of NMO Available (NHC and NMO share it by default) |
| WAO-INST-11 | Parity, all six | Run `test/cluster/parity.py --component C` for each of `nhc`, `snr`, `sbr`, `far`, `mdr` and `nmo` | Exit 0 for each (Deployments, `clusterPermissions` ClusterRoles, and each `permissions` Role plus its `<sa>-all-namespaces` ClusterRole and ClusterRoleBinding); SNR agent DaemonSet image equals the pinned SNR digest |
| WAO-INST-12 | WAO restart idempotence | Record `metadata.generation` and `resourceVersion` of every operand Deployment, the webhook configurations and the config; delete the WAO pod; wait 2 minutes | Generations unchanged; no operand pod restarted; the config's `resourceVersion` changes at most once; all conditions keep their `lastTransitionTime` |
| WAO-INST-13 | Drift repair and field ownership | Scale `sbr-operator-controller-manager` to 0 | WAO restores 2 replicas within 60 s; `managedFields` shows manager `workload-availability-operator` owning `spec.replicas` |
| WAO-INST-14 | Disable SBR, FAR, MDR | Patch the three states to `Disabled` | Each manager's Deployment, Services, ServiceAccounts, roles, bindings and webhooks removed; CRDs remain; each phase `Disabled` with no `retainedResources` |
| WAO-INST-15 | Disable NMO and NHC | Patch both to `Disabled` | Objects removed; both `Disabled`; `admissionReady: false` for both; NHC-created aggregation ClusterRole, ConsolePlugin and lease namespace recorded as left behind by upstream NHC, not by WAO |
| WAO-INST-16 | Disable SNR (manager level) | Patch `selfNodeRemediation.state: Disabled` | Manager and all four webhooks removed; `self-node-remediation-ds` still running; config, template and Secret retained; phase `DisableIncomplete` with `retainedResources` naming the DaemonSet and config; `Available=True` reason `DisableIncomplete`; `admissionReady: false`; a dry-run template DELETE now succeeds without admission (D2) |
| WAO-INST-17 | Delete the config | `delete wac cluster`, then delete the WAO pod | Finalizer completes; no operand Deployment or webhook remains; SNR agents, config, template, Secret and all CRDs retained; after the WAO pod restarts, a new all-Disabled `cluster` config exists |
| WAO-INST-18 | Uninstall and cleanup | Delete Subscription and CSV; record what remains; delete the SNR config so its DaemonSet is garbage-collected; delete the SNR template and Secret, the thirteen CRDs, the NHC aggregation role and binding, the ConsolePlugin, the `medik8s-leases` namespace if present, the catalog and the namespace | CSV and WAO Deployment gone; retained objects recorded before cleanup; final preflight (WAO-INST-00) passes again |

**Reporting.** Write `evidence/<date>-wao-poc/results.json` with one entry per case: `id`, `status` (pass, fail or blocked), `observed_at` in UTC and `notes`. Write a short `REPORT.md` beside it. Only sanitized copies of these two files may be committed, for example under `docs/results/`, and only after review.

A pass shows installation parity and lifecycle behavior of the POC. It says nothing about remediation, fencing, Machine deletion or drain safety. Enabling SNR (WAO-INST-06) starts real node agents.

**Safety.**
- Never create a real `NodeHealthCheck`, `StorageBasedRemediationConfig`, `FenceAgentsRemediation`, `MachineDeletionRemediation`, `NodeMaintenance` or `SelfNodeRemediation`. Admission checks use server dry-run.
- If a manager logs that it cannot find webhook certificates, check that the Secret mounted at `/tmp/k8s-webhook-server/serving-certs` contains `tls.crt` and `tls.key`.

## 5. Coverage and known risks

| Design brief requirement | Covered by |
| --- | --- |
| One package and CSV owning all twelve component CRDs and the WA config CRD (sections 2, 4, D8) | Tasks 3, 7; WAO-INST-02 |
| Six unchanged component managers as separate operands, pinned by digest (sections 2, 4) | Tasks 3–6; WAO-INST-05 to 10; WAO-INST-11 |
| Component selectors, service accounts and RBAC preserved; shared-namespace isolation (section 4, D10) | Task 3 extraction tests; WAO-INST-09, 11 |
| Admission via service-ca; no failurePolicy change (section 5, D1, D2) | Task 3 webhook generation; WAO-INST-05, 06, 08, 10, 16 |
| All components Disabled after install; nothing created (sections 6, 7, D4) | Task 6 bootstrap; WAO-INST-03, 04 |
| Honest disable status: agents and unreconciled native objects (section 7, D5) | Task 5 `retainedResources`, `ManagedKinds` and envtest specs; WAO-INST-14 to 16 |
| No owner references or adoption of administrator objects (section 4) | Task 5 foreign-object guard and envtest spec; WAO-INST-17 |
| No image override in the API; release set in status (section 6) | Tasks 2, 6, 7; WAO-INST-04 |
| Stable status, restart and drift behavior | Task 5 status-stability spec; WAO-INST-12, 13 |

**Known risks for the implementer:**

1. `operator-sdk generate bundle` may drop owned-CRD entries for CRDs whose Go types are not in this module. The CSV base lists all thirteen explicitly, and `hack/check-bundle.py` catches regressions.
2. Server-side apply can reject extracted fields the API server treats differently, such as an empty `strategy: {}`. If an apply fails on a field, strip empty maps in the extraction script and regenerate. Do not hand-edit the generated manifests.
3. The union role includes SCC `use` on `privileged`, because the SNR and SBR CSVs grant it, and NMO's `oauth.openshift.io` wildcard (D7). Call these out in the README's security notes.
4. ConfigMap-backed catalogs are a legacy OLM path. If the cluster refuses one, use the scaffolded FBC targets (`make catalog-build catalog-push`) instead.
5. In envtest, webhook configurations WAO creates have no backend. Specs must create native objects only while the owning component is Disabled (Task 5).
6. Upstream tags can move. The release set pins digests resolved on 2026-10-01; regenerate with `make bundles operand-manifests` only when deliberately changing versions.
7. NHC and NMO coordinate through node leases in the shared `medik8s-leases` namespace by default. WAO does not set `LEASE_NAMESPACE`, so both keep the upstream default.
