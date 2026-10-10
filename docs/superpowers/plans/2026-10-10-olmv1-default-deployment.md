# OLM v1 Only Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status: plan only. Nothing in this document has been implemented or run.

**Goal:** Make OLM v1 (`ClusterCatalog` + `ClusterExtension`, served by operator-controller and catalogd) the only way this repository builds, installs, verifies and uninstalls the Workload Availability Operator (WAO) on OpenShift, and delete the classic OLM path (ConfigMap-backed `CatalogSource`, `OperatorGroup`, `Subscription`, `InstallPlan`) from code, scripts and documentation.

**Architecture:** The registry+v1 bundle at `bundle/` stays as it is; the research found it already satisfies every hard OLM v1 content rule. Everything around it changes. A generator renders a File-Based Catalog (FBC) from `bundle/` and a digest-pinned bundle image reference, `opm validate` checks it, and a `FROM scratch` catalog image carries it under `/configs`. The cluster harness builds the operator image, the bundle image and the catalog image in the cluster's internal registry, applies a `ClusterCatalog` named `wao-poc`, creates the install namespace, applies installer RBAC generated from the CSV, and applies a `ClusterExtension` pinned to the exact bundle version. Cases 01, 02 and 18 of the harness are rewritten for OLM v1; the sixteen component cases between install and uninstall are untouched.

**Tech Stack:** Python 3 with PyYAML (`hack/`), bash 3.2-compatible scripts (`test/cluster/`), GNU make, `opm` (downloaded by the Makefile), OpenShift binary Docker builds in the internal registry, OLM v1 as shipped in OpenShift 4.18 and later (`olm.operatorframework.io/v1`).

**Spec:** [docs/investigations/olmv1/reports/OLM v1 operator requirements.md](../../investigations/olmv1/reports/OLM%20v1%20operator%20requirements.md) (the "Consolidated requirements checklist" section is the contract), the live-cluster note [07-live-cluster-ocp-5.0-rc5.md](../../investigations/olmv1/research_notes/OLM%20v1%20operator%20requirements/07-live-cluster-ocp-5.0-rc5.md), the prior experiments in [test/olmv1/README.md](../../../test/olmv1/README.md), and the project rules in [design-brief.md](../../design-brief.md) and [AGENTS.md](../../../AGENTS.md).

## Global Constraints

Every task inherits these. Values are copied from the spec and AGENTS.md.

- Do not modify, fork or rebuild the component operators. Consume upstream images exactly as pinned in `release-set.yaml`, by digest.
- Every component defaults to `Disabled`. Installing WAO creates no remediation policy, remediation request, native config or node agent.
- Never change a component webhook `failurePolicy`. WAO never adopts an object it did not create. No public API field overrides a component image.
- The bundle stays `registry+v1`, `AllNamespaces` only, one CSV plus thirteen CRDs in `manifests/`, no `spec.webhookdefinitions`, `apiservicedefinitions: {}`, no `metadata/dependencies.yaml`, no `olm.package.required`, `olm.gvk.required` or `olm.constraint` property.
- Package name `workload-availability-operator`, channel `alpha`, CSV `workload-availability-operator.v0.1.0`, version `0.1.0`. The `ClusterExtension` pins `version: "0.1.0"` exactly and `upgradeConstraintPolicy: CatalogProvided`. Moving to `1.0.0` for OLM v1's major-zero upgrade rules is a separate decision and out of scope here.
- Install namespace `openshift-workload-availability`, pre-created by the harness with the annotation `openshift.io/node-selector: ""` and the labels `pod-security.kubernetes.io/enforce=privileged`, `pod-security.kubernetes.io/audit=privileged`, `pod-security.kubernetes.io/warn=privileged`, `security.openshift.io/scc.podSecurityLabelSync=false` (what experiment 0001 used and what passed on 4.22 and 5.0).
- `ClusterCatalog` name `wao-poc`; `ClusterExtension` name `workload-availability-operator`; installer ServiceAccount `wao-installer`; catalog image label `operators.operatorframework.io.index.configs.v1=/configs`.
- The FBC `olm.bundle.image` and the `ClusterCatalog` `spec.source.image.ref` are always digest references (`@sha256:`); a `ClusterCatalog` with a digest ref must not set `pollIntervalMinutes`.
- Installer RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding) is always applied. It is required on OpenShift 4.18 through 4.22 and accepted with a deprecation warning and ignored on 5.0, where operator-controller runs as cluster-admin.
- No code, script, Makefile target or current-instruction documentation may reference `CatalogSource`, `OperatorGroup`, `Subscription`, `InstallPlan`, `PackageManifest` or `catalog-configmap` after this plan. Historical notes (README "Deviations from the plan", "Known upstream issues", experiment records in `test/olmv1/`) may keep them as history.
- Cluster commands always pass `--kubeconfig "$KUBECONFIG"`. Raw cluster output goes only to the git-ignored `evidence/`. Never capture Secret values. Admission checks use `--dry-run=server`. Never create a real `NodeHealthCheck`, `StorageBasedRemediationConfig`, `NodeMaintenance` or remediation request.
- Live-cluster tasks run only on a disposable OpenShift cluster the person you work for has confirmed in the current session.
- Keep `.cache/`, `evidence/`, `.venv/`, `dist/` and any kubeconfig out of Git and out of image build contexts.
- Small commits per task with a `wao:` prefix. Run `make test` and `make test-offline` before each commit.

## Review Focus

Inputs the spec implies but the task tests would otherwise not exercise, most likely to bite first. Each line names the owning task, which carries the pinned test.

1. A `ClusterExtension` applied on OpenShift 5.0, where `spec.serviceAccount` is ignored and the API server returns a deprecation warning on stderr, must still count as a successful apply and install. Task 7 records whether the field is required and Task 9 treats the warning as informational.
2. A bundle image given by tag instead of digest would make the FBC point at a mutable reference that operator-controller caches. Task 3 rejects any `--bundle-image` without `@sha256:`.
3. Deleting the `ClusterExtension` deletes all thirteen CRDs and every custom resource; a `SelfNodeRemediationConfig` with a finalizer and no running SNR manager would block that deletion. Task 10 deletes the SNR objects first, bounds every wait, and records leftovers instead of hanging.
4. A catalog image without the `operators.operatorframework.io.index.configs.v1` label is rejected by catalogd with no obvious hint. Task 5 pins the label in `catalog.Dockerfile` and the FBC directory layout `<package>/catalog.json`.
5. A cluster without OLM v1 (older than 4.18, or with the `NewOLM` feature disabled) must fail preflight with a message naming the missing API before anything is mutated, instead of failing later inside WAO-INST-01. Task 7 pins this with the first preflight check.

---

## 1. Scope and decisions

### In scope

1. FBC generation, validation and catalog image build from the existing bundle, for the internal registry and for external registries.
2. Committed OLM v1 install manifests: namespace, installer RBAC, `ClusterExtension`; rendered `ClusterCatalog`.
3. Deletion of the classic OLM path: `hack/configmap-catalog.py` and its test, the `catalog-configmap` target, the `opm index add` catalog target, the `CatalogSource`, `OperatorGroup`, `Subscription` and `InstallPlan` logic in `test/cluster/`, and every current-instruction mention in the docs.
4. The cluster harness (`test/cluster/`) uses OLM v1 for preflight, catalog, install and uninstall.
5. `full-run.sh build` builds the bundle and catalog images on the cluster and grants catalogd and operator-controller pull access.
6. Bundle checks for the OLM v1 content rules; OpenShift metadata annotations the research marks SHOULD.
7. Documentation: design brief decision update, AGENTS.md, README, TUTORIAL, agent run guide, harness READMEs.
8. One full live run on a confirmed disposable cluster.

### Out of scope

- Upgrades, a second bundle version, channel deprecations and the `1.0.0` version bump.
- Running OLM v1 in the Kind e2e (`make test-e2e` keeps deploying with kustomize; OLM v1 on Kind needs an in-cluster registry).
- Migration of an existing classic install to OLM v1 (experiments 0003 and 0005 in `test/olmv1/` cover adoption and stay as records).
- `containerImage` CSV annotation (it would need to track the per-cluster digest) and certification pipeline onboarding.
- Deleting `test/olmv1/`. Its generator produces the committed installer RBAC, and its scripts are the record of the experiments behind this plan.

### Decisions recorded by this plan

- **D6 (revised):** the catalog is an FBC image served by a `ClusterCatalog`. The ConfigMap-backed `CatalogSource` is deleted.
- **D11 (new):** OLM v1 is the only install path. The classic OLM path is removed from the repository. Rationale: the bundle already satisfies OLM v1's content rules, OLM v1 is GA and default-on from OpenShift 4.18, and WAO's runtime-created component webhooks (D1) make OLM v1's webhook limitations on 4.18 through 4.20 irrelevant.
- **D12 (new):** installer RBAC is generated from the CSV and committed under `config/olmv1/wao/`, and always applied. On 5.0 it is inert.

## 2. File structure

```
catalog.Dockerfile                         # FROM scratch; LABEL configs=/configs; COPY dist/catalog /configs      [create, Task 5]
hack/configmap-catalog.py                  # ConfigMap-backed CatalogSource renderer                                [delete, Task 2]
hack/configmap_catalog_test.py             #                                                                        [delete, Task 2]
hack/fbc-catalog.py                        # render FBC JSON from bundle/ + digest bundle image ref                 [create, Task 3]
hack/fbc_catalog_test.py                   # unit tests for the FBC generator                                       [create, Task 3]
hack/check-bundle.py                       # add OLM v1 content rules; drop the ConfigMap wording                   [modify, Tasks 2, 4]
hack/check_bundle_test.py                  # tests for check-bundle.py on mutated copies of bundle/                  [create, Task 4]
hack/clustercatalog.py                     # render the ClusterCatalog manifest for a catalog image digest ref       [create, Task 6]
hack/clustercatalog_test.py                #                                                                        [create, Task 6]
hack/bundle-annotations.py                 # post-process metadata/annotations.yaml and bundle.Dockerfile            [create, Task 13]
hack/bundle_annotations_test.py            #                                                                        [create, Task 13]
Makefile                                   # drop catalog-configmap and opm index add; add fbc, catalog-build,
                                           # clustercatalog, olmv1-manifests(-check); test-offline changes           [modify, Tasks 2-6, 13]
config/olmv1/namespace.yaml                # install namespace with node-selector annotation and PSA labels          [create, Task 6]
config/olmv1/wao/00-serviceaccount.yaml    # generated by test/olmv1/gen-installer-rbac.py --only wao               [generate, Task 6]
config/olmv1/wao/10-clusterrole.yaml       #
config/olmv1/wao/20-clusterrolebinding.yaml#
config/olmv1/wao/30-clusterextension.yaml  #
config/olmv1/wao/kustomization.yaml        #
config/olmv1/README.md                     # what is generated, how to regenerate                                    [create, Task 6]
config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml  # features.operators.openshift.io/* [modify, Task 13]
test/cluster/env.sh                        # drop CAT_NS/CATALOG/CATALOG_FILE; add CLUSTERCATALOG, CE_NAME, ...      [modify, Task 7]
test/cluster/olmv1.sh                      # OLM v1 predicates: ce_condition, ce_installed, catalog_serving, ...     [create, Task 7]
test/cluster/lib.sh                        # source olmv1.sh; snapshot records the ClusterExtension                  [modify, Task 7]
test/cluster/00-preflight.sh               # OLM v1 checks; classic checks removed                                   [modify, Task 7]
test/cluster/01-catalog.sh                 # ClusterCatalog Serving                                                  [rewrite, Task 8]
test/cluster/02-install-wao.sh             # namespace, installer RBAC, ClusterExtension                             [rewrite, Task 9]
test/cluster/18-uninstall.sh               # ClusterExtension deletion order and OLM v1 cleanup                      [modify, Task 10]
test/cluster/run-all.sh                    # RUN.md intended-mutations text                                          [modify, Task 10]
test/cluster/full-run.sh                   # build bundle + catalog images on the cluster; pull grants; ClusterCatalog [modify, Task 11]
docs/design-brief.md                       # D6 revised, D11, D12                                                    [modify, Task 1]
AGENTS.md                                  # cluster work: OLM v1                                                    [modify, Task 1]
docs/implementation-plan.md                # pointer from section 4 to this plan                                     [modify, Task 1]
README.md, TUTORIAL.md, docs/agent-test-run.md, test/cluster/README.md, test/olmv1/README.md  [modify, Task 12]
```

`dist/catalog/` and `dist/wao-poc-clustercatalog.yaml` are build outputs under the git-ignored `dist/`.

---

## 3. Tasks

### Task 1: Record the decision in the design brief, AGENTS.md and the implementation plan

**Files:**
- Modify: `docs/design-brief.md` (section 8 table, row D6; append D11 and D12)
- Modify: `AGENTS.md` ("Cluster work" section, first paragraph)
- Modify: `docs/implementation-plan.md` (section 4, first paragraph)

**Interfaces:**
- Produces: decision numbers D11 and D12 that later tasks and docs cite.

- [ ] **Step 1: Write the check that fails**

Run from the repository root:

```sh
grep -q 'D11' docs/design-brief.md && grep -q 'OLM v1' AGENTS.md && grep -q 'olmv1-default-deployment' docs/implementation-plan.md
```

Expected: exit 1 (none of the three strings exist yet).

- [ ] **Step 2: Revise D6 and add D11 and D12 in `docs/design-brief.md`**

Replace the D6 row with:

```markdown
| D6 | The catalog is a file-based catalog (FBC) image served by an OLM v1 `ClusterCatalog` named `wao-poc` | OLM v1's `ClusterCatalog` accepts only images; catalogd needs nothing but the FBC files under the labelled directory | Same |
```

Append after the D10 row:

```markdown
| D11 | OLM v1 (`ClusterExtension`) is the only install path; the classic OLM path (ConfigMap `CatalogSource`, `OperatorGroup`, `Subscription`, `InstallPlan`) is removed from the repository | The bundle already meets OLM v1's content rules; OLM v1 is GA and default-on from OpenShift 4.18; WAO's runtime-created component webhooks (D1) sidestep OLM v1's webhook limitations on 4.18–4.20; one path is one less thing to keep in parity | Same |
| D12 | Installer RBAC (ServiceAccount `wao-installer`, ClusterRole, ClusterRoleBinding) is generated from the CSV, committed under `config/olmv1/wao/` and always applied | Required on OpenShift 4.18–4.22; accepted with a deprecation warning and ignored on 5.0, where operator-controller runs as cluster-admin | Drop when every supported release ignores `spec.serviceAccount` |
```

- [ ] **Step 3: Update AGENTS.md "Cluster work"**

Replace the first paragraph of "Cluster work" with:

```markdown
Live-cluster tests (plan section 4) need a **disposable** OpenShift cluster, 4.18 or newer with
OLM v1 (`ClusterExtension` and `ClusterCatalog` APIs), that you are authorized to modify, selected
through the `KUBECONFIG` environment variable. The repository installs only through OLM v1 (D11);
classic OLM is not used. The repository never contains cluster credentials or cluster-identifying
details. Do not run cluster tests unless the person you are working for has confirmed which
cluster to use in the current session.
```

- [ ] **Step 4: Add the pointer in `docs/implementation-plan.md` section 4**

Insert after the first paragraph of "## 4. Live-cluster verification: install case":

```markdown
Superseded in part by [docs/superpowers/plans/2026-10-10-olmv1-default-deployment.md](superpowers/plans/2026-10-10-olmv1-default-deployment.md) (decisions D11 and D12): cases WAO-INST-00, 01, 02 and 18 now use OLM v1. 01 applies a `ClusterCatalog` instead of the CatalogSource, 02 applies the namespace, installer RBAC and a `ClusterExtension` instead of the OperatorGroup, Subscription and InstallPlan, and 18 deletes the `ClusterExtension`, which removes the thirteen CRDs itself. The rows below for those four cases describe the original classic OLM harness and are kept as history. Cases 03–17 are unchanged.
```

- [ ] **Step 5: Run the check**

Run the command from Step 1. Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add docs/design-brief.md AGENTS.md docs/implementation-plan.md
git commit -m "wao: decide OLM v1 as the only install path (D6 revised, D11, D12)"
```

---

### Task 2: Delete the ConfigMap-backed catalog and the legacy catalog target

**Files:**
- Delete: `hack/configmap-catalog.py`, `hack/configmap_catalog_test.py`
- Modify: `Makefile` (`CATALOG_NS`, `catalog-configmap`, the `opm index add` block: `BUNDLE_IMGS`, `CATALOG_BASE_IMG`, `FROM_INDEX_OPT`, `catalog-build`, `catalog-push`; `test-offline` unittest line)
- Modify: `hack/check-bundle.py` (one message)

**Interfaces:**
- Produces: a Makefile with no catalog target at all until Task 5 adds the OLM v1 ones; `make test-offline` still passes.

- [ ] **Step 1: Write the failing check**

Run:

```sh
! grep -rn 'configmap-catalog\|catalog-configmap\|opm index add\|CATALOG_NS\|ConfigMap catalog' Makefile hack/ && echo clean
```

Expected: matches are printed and `clean` is not (exit 1).

- [ ] **Step 2: Delete the files and Makefile pieces**

```sh
git rm hack/configmap-catalog.py hack/configmap_catalog_test.py
```

In the Makefile delete the `CATALOG_NS ?= openshift-marketplace` line and the whole `catalog-configmap` target (its `.PHONY` line, comment and two recipe lines). Delete the block that starts at the comment `# A comma-separated list of bundle images` and ends with the `catalog-push` recipe, including the `CATALOG_IMG ?=` line (Task 5 reintroduces `CATALOG_IMG` next to the new targets). Keep the `opm` download target. In `test-offline`, change the unittest line to:

```makefile
	$(PYTHON) -m unittest hack/extract_operand_manifests_test.py hack/e2e_runner_test.py
```

In `hack/check-bundle.py`, replace

```python
        problems.append(f"bundle contains objects a ConfigMap catalog cannot carry: {extra}")
```

with

```python
        problems.append(f"bundle contains objects beyond the POC contract (one CSV, thirteen CRDs): {extra}")
```

- [ ] **Step 3: Run the check and the offline suite**

Run the command from Step 1. Expected: `clean`.

Run: `make test-offline && make bundle-check`
Expected: pass; `bundle OK: workload-availability-operator.v0.1.0 owns 13 CRDs, 7 pinned operand images`.

- [ ] **Step 4: Commit**

```bash
git add -A Makefile hack
git commit -m "wao: remove the ConfigMap-backed CatalogSource and the sqlite catalog target"
```

---

### Task 3: FBC generator from the bundle directory

**Files:**
- Create: `hack/fbc-catalog.py`
- Create: `hack/fbc_catalog_test.py`
- Modify: `Makefile` (new `FBC_DIR`, `fbc` target; `test-offline` runs the new test; bump `opm` pin)

**Interfaces:**
- Produces: `python hack/fbc-catalog.py --bundle bundle --bundle-image <ref@sha256:...> --out <dir>` writes `<dir>/workload-availability-operator/catalog.json` (JSON, one object per line, schemas `olm.package`, `olm.channel`, `olm.bundle`) and exits 0; exits 2 with a message on a non-digest image ref or a bundle without exactly one CSV. `make fbc BUNDLE_IMG=<ref@sha256:...>` writes `dist/catalog/...` and runs `opm validate dist/catalog`.
- Consumes: `bundle/manifests/*.yaml`, `bundle/metadata/annotations.yaml`.

- [ ] **Step 1: Write the failing test**

Create `hack/fbc_catalog_test.py`:

```python
# hack/fbc_catalog_test.py
import json, pathlib, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = HERE.parent / "bundle"
BUNDLE_IMG = "image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-bundle@sha256:" + "a" * 64


def render(bundle=BUNDLE, image=BUNDLE_IMG):
    out = tempfile.mkdtemp()
    proc = subprocess.run([sys.executable, str(HERE / "fbc-catalog.py"), "--bundle", str(bundle),
                           "--bundle-image", image, "--out", out], capture_output=True, text=True)
    return proc, pathlib.Path(out)


class FBCTest(unittest.TestCase):
    def setUp(self):
        if not BUNDLE.exists():
            self.skipTest("bundle not generated")

    def blobs(self, out):
        path = out / "workload-availability-operator" / "catalog.json"
        self.assertTrue(path.exists(), f"{path} missing")
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def test_package_channel_and_bundle(self):
        proc, out = render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        blobs = self.blobs(out)
        by_schema = {b["schema"]: b for b in blobs}
        self.assertEqual(set(by_schema), {"olm.package", "olm.channel", "olm.bundle"})
        self.assertEqual(by_schema["olm.package"], {"schema": "olm.package", "name": "workload-availability-operator",
                                                    "defaultChannel": "alpha"})
        self.assertEqual(by_schema["olm.channel"]["entries"], [{"name": "workload-availability-operator.v0.1.0"}])
        bundle = by_schema["olm.bundle"]
        self.assertEqual(bundle["name"], "workload-availability-operator.v0.1.0")
        self.assertEqual(bundle["image"], BUNDLE_IMG)
        props = {p["type"]: p for p in bundle["properties"] if p["type"] != "olm.gvk"}
        self.assertEqual(props["olm.package"]["value"], {"packageName": "workload-availability-operator", "version": "0.1.0"})
        gvks = [p["value"] for p in bundle["properties"] if p["type"] == "olm.gvk"]
        # Twelve component CRDs plus the WorkloadAvailabilityConfig CRD, one olm.gvk each.
        self.assertEqual(len(gvks), 13)
        self.assertIn({"group": "workloadavailability.medik8s.io", "kind": "WorkloadAvailabilityConfig", "version": "v1alpha1"}, gvks)
        self.assertEqual(props["olm.csv.metadata"]["value"]["installModes"],
                         [{"type": "OwnNamespace", "supported": False}, {"type": "SingleNamespace", "supported": False},
                          {"type": "MultiNamespace", "supported": False}, {"type": "AllNamespaces", "supported": True}])
        # No dependency properties: OLM v1 rejects them.
        self.assertFalse({"olm.package.required", "olm.gvk.required", "olm.constraint"} & set(props))
        # relatedImages carries the CSV relatedImages (pinned operand images) plus the bundle image.
        images = {r["image"] for r in bundle["relatedImages"]}
        self.assertIn(BUNDLE_IMG, images)
        self.assertTrue(all("@sha256:" in i for i in images), images)

    def test_rejects_tag_reference(self):
        proc, _ = render(image="quay.io/example/wao-bundle:v0.1.0")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("digest", proc.stderr)

    def test_rejects_bundle_without_one_csv(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "manifests").mkdir()
            (pathlib.Path(d) / "metadata").mkdir()
            (pathlib.Path(d) / "metadata" / "annotations.yaml").write_text(
                yaml.safe_dump({"annotations": {"operators.operatorframework.io.bundle.package.v1": "x",
                                                "operators.operatorframework.io.bundle.channel.default.v1": "alpha",
                                                "operators.operatorframework.io.bundle.channels.v1": "alpha"}}))
            proc, _ = render(bundle=d)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("exactly one CSV", proc.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.venv/bin/python -m unittest hack/fbc_catalog_test.py -v`
Expected: FAIL, three errors with `No such file or directory: ... hack/fbc-catalog.py` (or returncode 2 mismatch).

- [ ] **Step 3: Write the generator**

Create `hack/fbc-catalog.py`:

```python
#!/usr/bin/env python3
# hack/fbc-catalog.py
"""Render a File-Based Catalog (FBC) for OLM v1 from a registry+v1 bundle directory (D6).

Writes <out>/<package>/catalog.json with one JSON object per line: olm.package, olm.channel,
olm.bundle. The bundle image must be a digest reference: operator-controller unpacks the bundle
image itself and caches it by reference, so a tag would make the catalog mutable.
"""
import argparse, json, pathlib, re, sys
import yaml

DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")
CSV_METADATA_FIELDS = ("annotations", "description", "displayName", "installModes", "keywords", "labels",
                       "links", "maintainers", "maturity", "minKubeVersion", "provider")


def fail(msg):
    print(f"fbc-catalog: {msg}", file=sys.stderr)
    sys.exit(2)


def load_bundle(bundle_dir):
    bundle = pathlib.Path(bundle_dir)
    ann = yaml.safe_load((bundle / "metadata" / "annotations.yaml").read_text())["annotations"]
    csvs, crds = [], []
    for f in sorted((bundle / "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csvs.append(obj)
        elif obj["kind"] == "CustomResourceDefinition":
            crds.append(obj)
    if len(csvs) != 1:
        fail(f"bundle must contain exactly one CSV, found {len(csvs)}")
    return ann, csvs[0], crds


def csv_metadata(csv):
    spec, meta = csv["spec"], csv["metadata"]
    value = {"annotations": meta.get("annotations", {})}
    for field in CSV_METADATA_FIELDS[1:]:
        if field in spec:
            value[field] = spec[field]
    owned = spec.get("customresourcedefinitions", {}).get("owned", [])
    value["crdDescriptions"] = {"owned": [{k: c[k] for k in ("name", "version", "kind", "displayName", "description") if k in c}
                                          for c in owned]}
    return value


def gvks(crds):
    out = []
    for crd in crds:
        for v in crd["spec"]["versions"]:
            if v.get("served", True):
                out.append({"group": crd["spec"]["group"], "kind": crd["spec"]["names"]["kind"], "version": v["name"]})
    return sorted(out, key=lambda g: (g["group"], g["kind"], g["version"]))


def related_images(csv, bundle_image):
    images = {ri["image"]: ri["name"] for ri in csv["spec"].get("relatedImages", []) or []}
    for d in csv["spec"]["install"]["spec"]["deployments"]:
        for c in d["spec"]["template"]["spec"]["containers"]:
            images.setdefault(c["image"], "")
    images.setdefault(bundle_image, "")
    return [{"name": name, "image": image} for image, name in sorted(images.items())]


def render(bundle_dir, bundle_image):
    if not DIGEST_RE.search(bundle_image):
        fail(f"--bundle-image must be a digest reference (…@sha256:<64 hex>), got {bundle_image!r}")
    ann, csv, crds = load_bundle(bundle_dir)
    package = ann["operators.operatorframework.io.bundle.package.v1"]
    default_channel = ann["operators.operatorframework.io.bundle.channel.default.v1"]
    channels = ann["operators.operatorframework.io.bundle.channels.v1"].split(",")
    name, version = csv["metadata"]["name"], str(csv["spec"]["version"])
    properties = [{"type": "olm.package", "value": {"packageName": package, "version": version}}]
    properties += [{"type": "olm.gvk", "value": g} for g in gvks(crds)]
    properties.append({"type": "olm.csv.metadata", "value": csv_metadata(csv)})
    blobs = [{"schema": "olm.package", "name": package, "defaultChannel": default_channel}]
    blobs += [{"schema": "olm.channel", "name": ch, "package": package, "entries": [{"name": name}]} for ch in channels]
    blobs.append({"schema": "olm.bundle", "name": name, "package": package, "image": bundle_image,
                  "properties": properties, "relatedImages": related_images(csv, bundle_image)})
    return package, blobs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", required=True, help="bundle directory (manifests/, metadata/)")
    ap.add_argument("--bundle-image", required=True, help="bundle image, digest reference")
    ap.add_argument("--out", required=True, help="FBC root directory, e.g. dist/catalog")
    a = ap.parse_args()
    package, blobs = render(a.bundle, a.bundle_image)
    out = pathlib.Path(a.out, package)
    out.mkdir(parents=True, exist_ok=True)
    (out / "catalog.json").write_text("".join(json.dumps(b, sort_keys=True) + "\n" for b in blobs))
    print(f"wrote {out / 'catalog.json'}: {len(blobs)} blobs, bundle {blobs[-1]['name']} -> {a.bundle_image}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `.venv/bin/python -m unittest hack/fbc_catalog_test.py -v`
Expected: PASS, 3 tests.

- [ ] **Step 5: Add the Makefile target and wire the test into `test-offline`**

In `Makefile`, after the `bundle-check` target add:

```makefile
FBC_DIR ?= dist/catalog
.PHONY: fbc
fbc: bundle-check opm ## Render the OLM v1 file-based catalog for BUNDLE_IMG (digest ref) into dist/catalog and validate it.
	rm -rf $(FBC_DIR)
	$(PYTHON) hack/fbc-catalog.py --bundle bundle --bundle-image $(BUNDLE_IMG) --out $(FBC_DIR)
	$(OPM) validate $(FBC_DIR)
```

Append `hack/fbc_catalog_test.py` to the unittest line of `test-offline`. Bump the pinned opm download in the `opm` target from `v1.55.0` to `v1.60.0` (the version operator-controller's own repository pins; `opm validate` exists in both; the release asset `darwin-arm64-opm` and the Linux ones exist for v1.60.0).

- [ ] **Step 6: Verify `make fbc` end to end with a fake digest**

Run:

```sh
make fbc BUNDLE_IMG=quay.io/example/wao-bundle@sha256:$(printf 'a%.0s' $(seq 64))
head -c 400 dist/catalog/workload-availability-operator/catalog.json
```

Expected: `opm validate` prints nothing and exits 0; the output file starts with `{"defaultChannel": "alpha", "name": "workload-availability-operator", "schema": "olm.package"}`.

- [ ] **Step 7: Run the offline suite and commit**

Run: `make test-offline`
Expected: all Python tests pass, every `test/cluster/*.sh` passes `bash -n`.

```bash
git add hack/fbc-catalog.py hack/fbc_catalog_test.py Makefile
git commit -m "wao: render an OLM v1 file-based catalog from the bundle"
```

---

### Task 4: OLM v1 content rules in `check-bundle.py`

**Files:**
- Modify: `hack/check-bundle.py`
- Create: `hack/check_bundle_test.py`
- Modify: `Makefile` (`test-offline` runs the new test)

**Interfaces:**
- Produces: `check-bundle.py` exits 1 with one line per problem for each OLM v1 rule below; `make bundle-check` is the gate for `make fbc` (already a prerequisite).

- [ ] **Step 1: Write the failing test**

Create `hack/check_bundle_test.py`:

```python
# hack/check_bundle_test.py
import pathlib, shutil, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
CSV_NAME = "workload-availability-operator.clusterserviceversion.yaml"


def check(bundle_dir):
    return subprocess.run([sys.executable, str(HERE / "check-bundle.py"), str(bundle_dir), str(REPO / "release-set.yaml")],
                          capture_output=True, text=True)


class CheckBundleTest(unittest.TestCase):
    def setUp(self):
        if not (REPO / "bundle").exists():
            self.skipTest("bundle not generated")
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.bundle = self.tmp / "bundle"
        shutil.copytree(REPO / "bundle", self.bundle)
        self.csv_path = self.bundle / "manifests" / CSV_NAME
        self.csv = yaml.safe_load(self.csv_path.read_text())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def save(self):
        self.csv_path.write_text(yaml.safe_dump(self.csv, sort_keys=False, width=4096))

    def test_committed_bundle_passes(self):
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("bundle OK", proc.stdout)

    def test_webhookdefinitions_rejected(self):
        self.csv["spec"]["webhookdefinitions"] = [{"type": "ValidatingAdmissionWebhook", "admissionReviewVersions": ["v1"],
                                                   "deploymentName": "x", "generateName": "x.kb.io", "sideEffects": "None"}]
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("webhookdefinitions", proc.stdout)

    def test_owned_apiservice_rejected(self):
        self.csv["spec"]["apiservicedefinitions"] = {"owned": [{"group": "g", "version": "v1", "kind": "K", "name": "v1.g",
                                                                "deploymentName": "x"}]}
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("apiservicedefinitions", proc.stdout)

    def test_non_semver_version_rejected(self):
        self.csv["spec"]["version"] = "0.1"
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("semver", proc.stdout)

    def test_dependencies_file_rejected(self):
        (self.bundle / "metadata" / "dependencies.yaml").write_text("dependencies: []\n")
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("dependencies.yaml", proc.stdout)

    def test_required_property_rejected(self):
        (self.bundle / "metadata" / "properties.yaml").write_text(yaml.safe_dump(
            {"properties": [{"type": "olm.package.required", "value": {"packageName": "x", "versionRange": ">=1.0.0"}}]}))
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("olm.package.required", proc.stdout)

    def test_extra_object_rejected(self):
        (self.bundle / "manifests" / "extra.yaml").write_text(yaml.safe_dump(
            {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "extra"}, "data": {}}))
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("ConfigMap/extra", proc.stdout)
        self.assertNotIn("ConfigMap catalog", proc.stdout)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.venv/bin/python -m unittest hack/check_bundle_test.py -v`
Expected: `test_committed_bundle_passes` and `test_extra_object_rejected` pass; the webhook, apiservice, semver, dependencies and required-property tests FAIL.

- [ ] **Step 3: Add the OLM v1 rules to `hack/check-bundle.py`**

Add after the imports:

```python
import re

SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
UNSUPPORTED_PROPERTIES = {"olm.package.required", "olm.gvk.required", "olm.constraint"}


def olmv1_problems(csv, bundle_dir):
    """Rules operator-controller enforces at install time (docs/investigations/olmv1, checklist MUST rows)."""
    spec, problems = csv["spec"], []
    if spec.get("webhookdefinitions"):
        problems.append("CSV spec.webhookdefinitions is set; OLM v1 only supports it on OpenShift 4.21+ and the POC keeps "
                        "component webhooks runtime-created (D1)")
    if (spec.get("apiservicedefinitions") or {}).get("owned"):
        problems.append("CSV spec.apiservicedefinitions.owned is set; OLM v1 rejects owned APIServices")
    if not SEMVER_RE.match(str(spec.get("version", ""))):
        problems.append(f"CSV spec.version {spec.get('version')!r} is not semver; OLM v1 resolves by semver")
    meta = pathlib.Path(bundle_dir, "metadata")
    if (meta / "dependencies.yaml").exists():
        problems.append("metadata/dependencies.yaml present; OLM v1 rejects bundle dependencies")
    props_file = meta / "properties.yaml"
    if props_file.exists():
        types = {p.get("type") for p in (yaml.safe_load(props_file.read_text()) or {}).get("properties", [])}
        for t in sorted(types & UNSUPPORTED_PROPERTIES):
            problems.append(f"metadata/properties.yaml declares {t}; OLM v1 rejects dependency properties")
    return problems
```

In `main()`, after `spec = csv["spec"]`, add `problems += olmv1_problems(csv, bundle_dir)`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `.venv/bin/python -m unittest hack/check_bundle_test.py -v`
Expected: PASS, 7 tests. Also run `make bundle-check`; expected `bundle OK: workload-availability-operator.v0.1.0 owns 13 CRDs, 7 pinned operand images`.

- [ ] **Step 5: Wire into `test-offline` and commit**

Append `hack/check_bundle_test.py` to the unittest line in the `test-offline` target. Run `make test-offline`.

```bash
git add hack/check-bundle.py hack/check_bundle_test.py Makefile
git commit -m "wao: check the bundle against the OLM v1 content rules"
```

---

### Task 5: Catalog image Dockerfile and Makefile catalog targets

**Files:**
- Create: `catalog.Dockerfile`
- Modify: `Makefile` (`CATALOG_IMG`, `catalog-build`, `catalog-push`)
- Modify: `hack/fbc_catalog_test.py` (Dockerfile assertions)

**Interfaces:**
- Produces: `make catalog-build BUNDLE_IMG=<digest ref> CATALOG_IMG=<tag>` builds a scratch image with the FBC at `/configs`; `make catalog-push CATALOG_IMG=<tag>` pushes it. `catalog.Dockerfile` is also the Dockerfile staged into the on-cluster binary build in Task 11.

- [ ] **Step 1: Write the failing test**

Append to `hack/fbc_catalog_test.py` inside `FBCTest`:

```python
    def test_catalog_dockerfile_serves_configs(self):
        text = (HERE.parent / "catalog.Dockerfile").read_text()
        self.assertIn("FROM scratch", text)
        self.assertIn("LABEL operators.operatorframework.io.index.configs.v1=/configs", text)
        self.assertIn("COPY dist/catalog /configs", text)
```

Run: `.venv/bin/python -m unittest hack/fbc_catalog_test.py -k dockerfile -v`
Expected: FAIL with `FileNotFoundError: ... catalog.Dockerfile`.

- [ ] **Step 2: Create `catalog.Dockerfile`**

```dockerfile
# catalog.Dockerfile: OLM v1 file-based catalog image (design brief D6).
# catalogd reads only the directory named by the configs label; no opm binary or cache is needed.
# Build context is the repository root after `make fbc` wrote dist/catalog/.
# For an OpenShift binary build (test/cluster/full-run.sh) the same file is staged as `Dockerfile`
# next to a `dist/catalog/` copy, so the COPY path is identical.
FROM scratch
LABEL operators.operatorframework.io.index.configs.v1=/configs
COPY dist/catalog /configs
```

- [ ] **Step 3: Add the catalog targets to the Makefile**

After the `fbc` target add:

```makefile
# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

.PHONY: catalog-build
catalog-build: fbc ## Build the OLM v1 catalog image (FROM scratch, FBC at /configs) for BUNDLE_IMG.
	$(CONTAINER_TOOL) build -f catalog.Dockerfile -t $(CATALOG_IMG) .

.PHONY: catalog-push
catalog-push: ## Push the catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)
```

- [ ] **Step 4: Run the tests**

Run: `.venv/bin/python -m unittest hack/fbc_catalog_test.py -v`
Expected: PASS, 4 tests.

Run: `make -n catalog-build BUNDLE_IMG=quay.io/example/wao-bundle@sha256:$(printf 'a%.0s' $(seq 64))`
Expected: the dry run prints the `fbc-catalog.py`, `opm validate` and `docker build -f catalog.Dockerfile` commands.

- [ ] **Step 5: Commit**

```bash
git add catalog.Dockerfile Makefile hack/fbc_catalog_test.py
git commit -m "wao: build the OLM v1 catalog image from the file-based catalog"
```

---

### Task 6: Committed OLM v1 install manifests and the ClusterCatalog renderer

**Files:**
- Create: `config/olmv1/namespace.yaml`, `config/olmv1/README.md`
- Generate: `config/olmv1/wao/{00-serviceaccount,10-clusterrole,20-clusterrolebinding,30-clusterextension,kustomization}.yaml`
- Create: `hack/clustercatalog.py`, `hack/clustercatalog_test.py`
- Modify: `Makefile` (`olmv1-manifests`, `olmv1-manifests-check`, `clustercatalog`; `test-offline` additions)

**Interfaces:**
- Produces: `make olmv1-manifests` regenerates `config/olmv1/wao/`; `make olmv1-manifests-check` fails if they are stale; `make clustercatalog CATALOG_IMG=<digest ref>` writes `dist/wao-poc-clustercatalog.yaml`; `python hack/clustercatalog.py --name wao-poc --image <digest ref>` prints the manifest.
- Consumes: `test/olmv1/gen-installer-rbac.py --only wao --out <dir>` (exists; writes `<dir>/wao/*.yaml` with repository-relative header comments).

- [ ] **Step 1: Write the failing tests**

Create `hack/clustercatalog_test.py`:

```python
# hack/clustercatalog_test.py
import pathlib, subprocess, sys, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
IMG = "image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-catalog@sha256:" + "b" * 64


def render(image=IMG):
    return subprocess.run([sys.executable, str(HERE / "clustercatalog.py"), "--name", "wao-poc", "--image", image],
                          capture_output=True, text=True)


class ClusterCatalogTest(unittest.TestCase):
    def test_manifest(self):
        proc = render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        obj = yaml.safe_load(proc.stdout)
        self.assertEqual(obj["apiVersion"], "olm.operatorframework.io/v1")
        self.assertEqual(obj["kind"], "ClusterCatalog")
        self.assertEqual(obj["metadata"]["name"], "wao-poc")
        self.assertEqual(obj["spec"], {"availabilityMode": "Available", "priority": 0,
                                       "source": {"type": "Image", "image": {"ref": IMG}}})
        # A digest reference must not carry pollIntervalMinutes (CRD validation rejects it).
        self.assertNotIn("pollIntervalMinutes", proc.stdout)

    def test_rejects_tag_reference(self):
        proc = render(image="quay.io/example/wao-catalog:latest")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("digest", proc.stderr)


class GeneratedManifestsTest(unittest.TestCase):
    """config/olmv1/wao is generated; its headers must not embed a workstation path."""

    def test_no_absolute_paths_in_generated_files(self):
        files = list((HERE.parent / "config" / "olmv1" / "wao").glob("*.yaml"))
        self.assertEqual(len(files), 5, files)
        for f in files:
            for line in f.read_text().splitlines():
                self.assertNotRegex(line, r"(/Users/|/home/)", f"{f}: {line}")

    def test_clusterextension_pins_catalog_and_version(self):
        ce = yaml.safe_load((HERE.parent / "config" / "olmv1" / "wao" / "30-clusterextension.yaml").read_text())
        self.assertEqual(ce["metadata"]["name"], "workload-availability-operator")
        self.assertEqual(ce["spec"]["namespace"], "openshift-workload-availability")
        self.assertEqual(ce["spec"]["serviceAccount"], {"name": "wao-installer"})
        cat = ce["spec"]["source"]["catalog"]
        self.assertEqual(cat["packageName"], "workload-availability-operator")
        self.assertEqual(cat["channels"], ["alpha"])
        self.assertEqual(cat["version"], "0.1.0")
        self.assertEqual(cat["upgradeConstraintPolicy"], "CatalogProvided")
        self.assertEqual(cat["selector"], {"matchLabels": {"olm.operatorframework.io/metadata.name": "wao-poc"}})

    def test_namespace_manifest(self):
        ns = yaml.safe_load((HERE.parent / "config" / "olmv1" / "namespace.yaml").read_text())
        self.assertEqual(ns["metadata"]["name"], "openshift-workload-availability")
        self.assertEqual(ns["metadata"]["annotations"]["openshift.io/node-selector"], "")
        labels = ns["metadata"]["labels"]
        for key in ("pod-security.kubernetes.io/enforce", "pod-security.kubernetes.io/audit", "pod-security.kubernetes.io/warn"):
            self.assertEqual(labels[key], "privileged")
        self.assertEqual(labels["security.openshift.io/scc.podSecurityLabelSync"], "false")


if __name__ == "__main__":
    unittest.main()
```

Run: `.venv/bin/python -m unittest hack/clustercatalog_test.py -v`
Expected: FAIL (script and files missing).

- [ ] **Step 2: Write `hack/clustercatalog.py`**

```python
#!/usr/bin/env python3
# hack/clustercatalog.py
"""Print the OLM v1 ClusterCatalog manifest for a catalog image (digest reference only)."""
import argparse, re, sys
import yaml

DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True)
    ap.add_argument("--image", required=True, help="catalog image, digest reference")
    a = ap.parse_args()
    if not DIGEST_RE.search(a.image):
        print(f"clustercatalog: --image must be a digest reference (…@sha256:<64 hex>), got {a.image!r}", file=sys.stderr)
        sys.exit(2)
    obj = {"apiVersion": "olm.operatorframework.io/v1", "kind": "ClusterCatalog",
           "metadata": {"name": a.name},
           "spec": {"availabilityMode": "Available", "priority": 0,
                    "source": {"type": "Image", "image": {"ref": a.image}}}}
    print(yaml.safe_dump(obj, sort_keys=False, width=4096), end="")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Create `config/olmv1/namespace.yaml`**

```yaml
# config/olmv1/namespace.yaml: the install namespace. OLM v1 does not create it.
# Privileged PSA labels: the SNR and SBR node agents WAO's operands create run privileged.
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  annotations:
    openshift.io/node-selector: ""
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
```

- [ ] **Step 4: Confirm the generator headers are repository-relative**

`render_clusterrole()` in `test/olmv1/gen-installer-rbac.py` already writes `os.path.relpath(csv_path, REPO)` and `os.path.relpath(bundle_dir, REPO)` into its header comments (lines 548–549), so no code change is expected. Verify that no generated text embeds a workstation path:

```sh
grep -n '/Users/\|/home/' test/olmv1/rbac/wao/*.yaml; echo "exit $?"
```

Expected: no matches, `exit 1`. If a match appears, wrap that path with `os.path.relpath(..., REPO)` where it is formatted and re-run the existing generator tests: `.venv/bin/python test/olmv1/gen_installer_rbac_test.py -v` (they need `.cache/bundles` and the experiment CSVs; if they skip for a missing input, note it and continue). `GeneratedManifestsTest.test_no_absolute_paths_in_generated_files` from Step 1 guards this permanently.

- [ ] **Step 5: Add the Makefile targets and generate**

Add to the Makefile after the `catalog-push` target:

```makefile
OLMV1_DIR ?= config/olmv1
.PHONY: olmv1-manifests olmv1-manifests-check
olmv1-manifests: bundle-check ## Regenerate the OLM v1 installer RBAC and ClusterExtension for the WAO bundle into config/olmv1/wao.
	$(PYTHON) test/olmv1/gen-installer-rbac.py --only wao --out $(OLMV1_DIR)
olmv1-manifests-check: ## Verify config/olmv1/wao is current for the committed bundle.
	@tmp=$$(mktemp -d) && $(PYTHON) test/olmv1/gen-installer-rbac.py --only wao --out $$tmp >/dev/null && \
	  diff -r $$tmp/wao $(OLMV1_DIR)/wao && rm -rf $$tmp && echo "config/olmv1/wao is current"

CLUSTERCATALOG_FILE ?= dist/wao-poc-clustercatalog.yaml
.PHONY: clustercatalog
clustercatalog: ## Render the ClusterCatalog for CATALOG_IMG (digest ref) into dist/wao-poc-clustercatalog.yaml.
	mkdir -p dist
	$(PYTHON) hack/clustercatalog.py --name wao-poc --image $(CATALOG_IMG) > $(CLUSTERCATALOG_FILE)
```

Append `hack/clustercatalog_test.py` to the unittest line in `test-offline`, and add a line `$(MAKE) olmv1-manifests-check` at the end of the `test-offline` recipe.

Run: `make olmv1-manifests`
Expected: `wrote 5 files under config/olmv1`, directory `config/olmv1/wao/` with the five files.

- [ ] **Step 6: Write `config/olmv1/README.md`**

```markdown
# OLM v1 install manifests

`namespace.yaml` is hand-written. Everything under `wao/` is **generated** from the committed
bundle by `test/olmv1/gen-installer-rbac.py --only wao` (`make olmv1-manifests`); do not edit it,
regenerate it. `make olmv1-manifests-check` (part of `make test-offline`) fails when it is stale.

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Install namespace with `openshift.io/node-selector: ""` and privileged PSA labels |
| `wao/00-serviceaccount.yaml` | Installer ServiceAccount `wao-installer` (D12) |
| `wao/10-clusterrole.yaml` | Everything OLM v1 renders from the bundle, following the OpenShift 4.22 "Creating a cluster role for an extension" procedure |
| `wao/20-clusterrolebinding.yaml` | Binds the ClusterRole to `wao-installer` |
| `wao/30-clusterextension.yaml` | `ClusterExtension` pinned to version `0.1.0`, channel `alpha`, catalog `wao-poc` |

The `ClusterCatalog` is not committed: its image reference is a per-cluster digest. Render it with
`make clustercatalog CATALOG_IMG=<catalog image>@sha256:…` into `dist/wao-poc-clustercatalog.yaml`.

On OpenShift 5.0 `spec.serviceAccount` is deprecated and ignored; applying the RBAC is harmless
there and still required on 4.18–4.22.
```

- [ ] **Step 7: Run the tests**

Run: `.venv/bin/python -m unittest hack/clustercatalog_test.py -v`
Expected: PASS, 5 tests.

Run: `make test-offline`
Expected: pass, ending with `config/olmv1/wao is current`.

- [ ] **Step 8: Commit**

```bash
git add config/olmv1 hack/clustercatalog.py hack/clustercatalog_test.py Makefile
git commit -m "wao: commit the OLM v1 installer RBAC, ClusterExtension and namespace; render the ClusterCatalog"
```

---

### Task 7: Harness settings, OLM v1 helpers and preflight

**Files:**
- Modify: `test/cluster/env.sh`
- Create: `test/cluster/olmv1.sh`
- Modify: `test/cluster/lib.sh` (source `olmv1.sh`; `snapshot`)
- Modify: `test/cluster/00-preflight.sh`

**Interfaces:**
- Produces, in `env.sh`: `CLUSTERCATALOG=wao-poc`, `CLUSTERCATALOG_FILE=${REPO_ROOT}/dist/wao-poc-clustercatalog.yaml`, `CE_NAME=workload-availability-operator`, `OLMV1_DIR=${REPO_ROOT}/config/olmv1`. Removes `CAT_NS`, `CATALOG`, `CATALOG_FILE`. Keeps `CSV_NAME` (it is the bundle name OLM v1 reports in `status.install.bundle.name`).
- Produces, in `olmv1.sh`: `ce_condition NAME TYPE` (prints `status/reason`), `ce_installed NAME`, `ce_progressing_succeeded NAME`, `ce_installed_bundle NAME` (prints `status.install.bundle.name`), `catalog_serving NAME`, `ce_sa_required` (exit 0 when the ClusterExtension CRD lists `serviceAccount` in `spec.required`), `olmv1_present`.
- Consumed by Tasks 8, 9, 10, 11.

- [ ] **Step 1: Write the failing check**

Run:

```sh
KUBECONFIG=/dev/null bash -c 'source test/cluster/env.sh; [ "${CE_NAME:-}" = workload-availability-operator ] && [ -z "${CAT_NS:-}" ]'
```

Expected: exit 1.

- [ ] **Step 2: Rewrite the catalog settings in `test/cluster/env.sh`**

Delete the three lines defining `CAT_NS`, `CATALOG` and `CATALOG_FILE`. Add after the `CSV_NAME` line:

```sh
export CLUSTERCATALOG="${CLUSTERCATALOG:-wao-poc}"
export CLUSTERCATALOG_FILE="${CLUSTERCATALOG_FILE:-${REPO_ROOT}/dist/wao-poc-clustercatalog.yaml}"
export CE_NAME="${CE_NAME:-workload-availability-operator}"
export OLMV1_DIR="${OLMV1_DIR:-${REPO_ROOT}/config/olmv1}"
```

Then confirm nothing else in the harness still reads the removed names:

```sh
grep -n 'CAT_NS\|\$CATALOG\b\|CATALOG_FILE' test/cluster/*.sh
```

Expected after Tasks 8–11: no matches. At this point matches in `01-catalog.sh`, `02-install-wao.sh`, `18-uninstall.sh`, `00-preflight.sh` and `full-run.sh` are expected; the preflight ones are removed in Step 5 of this task, the others in their own tasks.

- [ ] **Step 3: Create `test/cluster/olmv1.sh`**

```sh
# test/cluster/olmv1.sh — OLM v1 (ClusterExtension / ClusterCatalog) predicates for the install cases.
# shellcheck shell=bash
# Sourced by lib.sh after k, jcheck, found and absent are defined. Bash 3.2 compatible.
# Every predicate fails on an API error; "absent" is never inferred from an error.

# ce_condition NAME TYPE : print "status/reason" of a ClusterExtension condition, or "absent".
ce_condition() {
  k get clusterextension "$1" -o json | python3 -c '
import json, sys
o = json.load(sys.stdin)
c = [x for x in o.get("status", {}).get("conditions", []) if x["type"] == sys.argv[1]]
print((c[0]["status"] + "/" + c[0].get("reason", "")) if c else "absent")' "$2"
}
ce_installed() { [ "$(ce_condition "$1" Installed)" = "True/Succeeded" ]; }
ce_progressing_succeeded() { [ "$(ce_condition "$1" Progressing)" = "True/Succeeded" ]; }
# ce_installed_bundle NAME : print status.install.bundle.name (empty until installed).
ce_installed_bundle() { k get clusterextension "$1" -o jsonpath='{.status.install.bundle.name}'; }
# catalog_serving NAME : the ClusterCatalog reports Serving=True.
catalog_serving() {
  jcheck 'any(c["type"] == "Serving" and c["status"] == "True" for c in o.get("status", {}).get("conditions", []))' \
    get clustercatalog "$1"
}
olmv1_present() {
  found crd clusterextensions.olm.operatorframework.io >/dev/null && found crd clustercatalogs.olm.operatorframework.io >/dev/null
}
# ce_sa_required : exit 0 when the ClusterExtension CRD still requires spec.serviceAccount (OpenShift 4.18–4.22);
# exit 1 when the field is optional and ignored (OpenShift 5.0+). Any API error exits 1 as well.
ce_sa_required() {
  jcheck '"serviceAccount" in next(v for v in o["spec"]["versions"] if v.get("storage"))["schema"]["openAPIV3Schema"]["properties"]["spec"].get("required", [])' \
    get crd clusterextensions.olm.operatorframework.io
}
```

- [ ] **Step 4: Source it from `lib.sh` and record the ClusterExtension in `snapshot`**

In `test/cluster/lib.sh`, after the `absent()` definition add:

```sh
source "$(dirname "${BASH_SOURCE[0]}")/olmv1.sh"
```

In `snapshot()`, replace the `record "${l}-csv" get csv -n "$NS" -o json >/dev/null || true` line with:

```sh
  record "${l}-ce" get clusterextension "$CE_NAME" -o json >/dev/null || true
```

- [ ] **Step 5: Rewrite the OLM checks in preflight**

In `test/cluster/00-preflight.sh`, replace the two `expect "classic OLM is present..."` lines with:

```sh
# Review Focus 5: fail here, by name, on a cluster without OLM v1 (OpenShift < 4.18 or NewOLM disabled).
expect "OLM v1 is present (clusterextensions and clustercatalogs CRDs in olm.operatorframework.io)" olmv1_present
expect "operator-controller is Available in openshift-operator-controller" \
  k wait deployment/operator-controller-controller-manager -n openshift-operator-controller --for=condition=Available --timeout=10s
expect "no ClusterExtension $CE_NAME exists" absent clusterextension "$CE_NAME"
if ce_sa_required; then sa_mode="required"; else sa_mode="ignored (deprecated; operator-controller runs as cluster-admin)"; fi
echo "note: ClusterExtension.spec.serviceAccount is ${sa_mode} on this cluster; installer RBAC is applied either way (D12)"
record 00-operator-controller get deployment operator-controller-controller-manager -n openshift-operator-controller -o json >/dev/null
record 00-clustercatalogs get clustercatalog -o json >/dev/null
if ! absent clustercatalog "$CLUSTERCATALOG" >/dev/null 2>&1; then
  echo "note: ClusterCatalog $CLUSTERCATALOG already exists (WAO-INST-01 re-applies it)"
fi
```

Standalone medik8s operators may still be installed through classic OLM on the test cluster, so the CSV check stays, but it must tolerate a cluster without that API. Replace `expect "no standalone medik8s operator CSVs (and no WAO CSV) exist" no_medik8s_csvs` with:

```sh
if found crd clusterserviceversions.operators.coreos.com >/dev/null 2>&1; then
  expect "no standalone medik8s operator CSVs exist" no_medik8s_csvs
else
  echo "note: classic OLM absent; CSV check skipped"
fi
```

Delete the block `if ! absent catalogsource "$CATALOG" -n "$CAT_NS" ...; then ... fi`.

Extend the image check to the catalog image. After the existing WAO image block add:

```sh
if [ "${SKIP_IMAGE_CHECK:-0}" != 1 ]; then
  if [ -f "$CLUSTERCATALOG_FILE" ]; then
    cat_image=$(grep -m1 -Eo 'ref: image-registry\.openshift-image-registry\.svc:5000/[^ ]+' "$CLUSTERCATALOG_FILE" | sed 's/^ref: //' || true)
    if [ -n "$cat_image" ]; then
      path="${cat_image#image-registry.openshift-image-registry.svc:5000/}"
      img_ns="${path%%/*}"; img_ref="${path#*/}"
      expect "catalog image $img_ref exists in the internal registry (namespace $img_ns)" found imagestreamimage "$img_ref" -n "$img_ns"
    fi
  else
    echo "note: $CLUSTERCATALOG_FILE missing; run \`bash test/cluster/full-run.sh build\` before WAO-INST-01"
  fi
fi
```

Append `- ClusterExtension.spec.serviceAccount: ${sa_mode}` to the RUN.md block at the end of the script.

- [ ] **Step 6: Verify offline**

Run:

```sh
KUBECONFIG=/dev/null bash -c 'source test/cluster/env.sh; [ "$CE_NAME" = workload-availability-operator ] && [ -z "${CAT_NS:-}" ]' && echo env-ok
grep -n 'CAT_NS\|\$CATALOG\b\|CATALOG_FILE' test/cluster/00-preflight.sh test/cluster/lib.sh test/cluster/env.sh; echo "exit $?"
make test-offline
```

Expected: `env-ok`; no grep matches, `exit 1`; `test-offline` passes (it syntax-checks every `test/cluster/*.sh`, now including `olmv1.sh`).

- [ ] **Step 7: Commit**

```bash
git add test/cluster/env.sh test/cluster/olmv1.sh test/cluster/lib.sh test/cluster/00-preflight.sh
git commit -m "wao: harness settings, OLM v1 predicates and preflight"
```

---

### Task 8: WAO-INST-01 applies the ClusterCatalog

**Files:**
- Rewrite: `test/cluster/01-catalog.sh`

**Interfaces:**
- Consumes: `CLUSTERCATALOG`, `CLUSTERCATALOG_FILE`, `catalog_serving` (Task 7); `dist/wao-poc-clustercatalog.yaml` (Task 6, rendered by Task 11).
- Produces: a Serving `ClusterCatalog` named `wao-poc` whose `status.resolvedSource.image.ref` is a digest.

- [ ] **Step 1: Write the failing check**

Run: `grep -q clustercatalog test/cluster/01-catalog.sh`
Expected: exit 1.

- [ ] **Step 2: Rewrite `test/cluster/01-catalog.sh`**

```sh
#!/usr/bin/env bash
# test/cluster/01-catalog.sh — WAO-INST-01: the WAO ClusterCatalog serves the package.
# Applies the ClusterCatalog rendered by `make clustercatalog` (full-run.sh build) and waits for Serving=True.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-01 catalog"
[ -f "$CLUSTERCATALOG_FILE" ] || { echo "FAIL: $CLUSTERCATALOG_FILE missing; run \`bash test/cluster/full-run.sh build\`" >&2; exit 1; }
record 01-apply-clustercatalog apply -f "$CLUSTERCATALOG_FILE" >/dev/null
wait_for 300 "ClusterCatalog $CLUSTERCATALOG Serving" catalog_serving "$CLUSTERCATALOG"
record 01-clustercatalog get clustercatalog "$CLUSTERCATALOG" -o json >/dev/null
expect "ClusterCatalog $CLUSTERCATALOG is Serving" catalog_serving "$CLUSTERCATALOG"
expect "ClusterCatalog $CLUSTERCATALOG resolved its image to a digest" \
  jcheck '"@sha256:" in o["status"]["resolvedSource"]["image"]["ref"]' get clustercatalog "$CLUSTERCATALOG"
expect "ClusterCatalog $CLUSTERCATALOG carries the name label the ClusterExtension selector uses" \
  jcheck 'o["metadata"]["labels"].get("olm.operatorframework.io/metadata.name") == os.environ["CLUSTERCATALOG"]' \
  get clustercatalog "$CLUSTERCATALOG"
```

- [ ] **Step 3: Verify offline**

Run: `bash -n test/cluster/01-catalog.sh && ! grep -n 'catalogsource\|packagemanifest\|CAT_NS' test/cluster/01-catalog.sh && echo clean`
Expected: `clean`.

- [ ] **Step 4: Commit**

```bash
git add test/cluster/01-catalog.sh
git commit -m "wao: WAO-INST-01 applies the ClusterCatalog"
```

---

### Task 9: WAO-INST-02 installs through a ClusterExtension

**Files:**
- Rewrite: `test/cluster/02-install-wao.sh`

**Interfaces:**
- Consumes: `config/olmv1/namespace.yaml`, `config/olmv1/wao/*.yaml` (Task 6), `ce_installed`, `ce_progressing_succeeded`, `ce_installed_bundle`, `CE_NAME`, `OLMV1_DIR` (Task 7); `ALL_CRDS`, `only_wao_deployment`, `crds_present`, `deployment_available`, `snapshot` (already in `lib.sh`, `ALL_CRDS` at line 24).
- Produces: WAO installed with all thirteen CRDs labelled `olm.operatorframework.io/owner-name=workload-availability-operator`.

- [ ] **Step 1: Write the failing check**

Run: `grep -q clusterextension test/cluster/02-install-wao.sh`
Expected: exit 1.

- [ ] **Step 2: Rewrite `test/cluster/02-install-wao.sh`**

```sh
#!/usr/bin/env bash
# test/cluster/02-install-wao.sh — WAO-INST-02: install WAO through OLM v1.
# Namespace, installer RBAC (D12) and the ClusterExtension pinned to 0.1.0; wait for Installed=True/Succeeded.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-02 install"
record 02-namespace apply -f "$OLMV1_DIR/namespace.yaml" >/dev/null
for f in 00-serviceaccount 10-clusterrole 20-clusterrolebinding; do
  record "02-installer-$f" apply -f "$OLMV1_DIR/wao/$f.yaml" >/dev/null
done
# On OpenShift 5.0 the API server answers with a deprecation warning for spec.serviceAccount; `record`
# keeps stderr in the evidence and the apply still exits 0 (Review Focus 1).
record 02-clusterextension apply -f "$OLMV1_DIR/wao/30-clusterextension.yaml" >/dev/null

progress() { k get clusterextension "$CE_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}: {.message}{end}' 2>/dev/null | cut -c1-300; }
start=$(date +%s)
until ce_installed "$CE_NAME"; do
  msg=$(progress)
  echo "t+$(( $(date +%s) - start ))s $msg"
  case "$msg" in
    *forbidden*|*"cannot be managed"*|*"already exists"*)
      record 02-clusterextension-failed get clusterextension "$CE_NAME" -o json >/dev/null
      echo "FAIL: ClusterExtension $CE_NAME: $msg" >&2; exit 1 ;;
  esac
  if (( $(date +%s) - start > 600 )); then
    record 02-clusterextension-timeout get clusterextension "$CE_NAME" -o json >/dev/null
    echo "TIMEOUT: ClusterExtension $CE_NAME Installed" >&2; exit 1
  fi
  sleep 10
done
record 02-clusterextension-status get clusterextension "$CE_NAME" -o json >/dev/null
expect "ClusterExtension $CE_NAME Installed=True/Succeeded" ce_installed "$CE_NAME"
expect "ClusterExtension $CE_NAME Progressing=True/Succeeded" ce_progressing_succeeded "$CE_NAME"
expect "installed bundle is $CSV_NAME" test "$(ce_installed_bundle "$CE_NAME")" = "$CSV_NAME"
wait_for 180 "WAO Deployment Available" deployment_available "$WAO_DEPLOYMENT"
expect "exactly one Deployment (the WAO controller)" only_wao_deployment
expect "all thirteen CRDs exist" crds_present "$ALL_CRDS"
expect "all thirteen CRDs are owned by the ClusterExtension" jcheck \
  'len([c for c in o["items"] if "medik8s.io" in c["metadata"]["name"] and c["metadata"].get("labels", {}).get("olm.operatorframework.io/owner-name") == os.environ["CE_NAME"]]) == 13' \
  get crd
snapshot 02
```

- [ ] **Step 3: Verify offline**

Run: `bash -n test/cluster/02-install-wao.sh && ! grep -n 'operatorgroup\|subscription\|installplan\|csv ' test/cluster/02-install-wao.sh && make test-offline`
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add test/cluster/02-install-wao.sh
git commit -m "wao: WAO-INST-02 installs through a ClusterExtension"
```

---

### Task 10: WAO-INST-18 uninstalls through the ClusterExtension and run-all describes the mutations

**Files:**
- Modify: `test/cluster/18-uninstall.sh`
- Modify: `test/cluster/run-all.sh` (RUN.md heredoc)

**Interfaces:**
- Consumes: `CE_NAME`, `CLUSTERCATALOG`, `OLMV1_DIR` (Task 7).
- Produces: a cluster that passes WAO-INST-00 again.

Deletion order matters (Review Focus 3): deleting the `ClusterExtension` deletes the thirteen CRDs and every custom resource. The SNR objects go first, while their CRDs still exist and any stuck finalizer can be cleared explicitly; then the `ClusterExtension`; the existing CRD cleanup in section 4 stays as a no-op fallback because every step is `--ignore-not-found`.

- [ ] **Step 1: Write the failing check**

Run: `grep -q 'delete clusterextension' test/cluster/18-uninstall.sh`
Expected: exit 1.

- [ ] **Step 2: Replace the uninstall step**

In `test/cluster/18-uninstall.sh`, replace section "2. Uninstall WAO through OLM." (the four lines from `record 18-delete-subscription` through `expect "WAO Deployment gone" ...`) with:

```sh
# 2. Uninstall WAO through OLM v1. Deleting the ClusterExtension deletes the thirteen CRDs and therefore every CR.
# Remove the SNR objects first, while a stuck finalizer can still be cleared explicitly; otherwise the deletion could hang.
if found selfnoderemediationconfig self-node-remediation-config -n "$NS" >/dev/null 2>&1; then
  record 18-delete-snr-config delete selfnoderemediationconfig self-node-remediation-config -n "$NS" --wait=false >/dev/null || fail "delete SNR config"
  if ! wait_for 120 "SNR config gone" absent selfnoderemediationconfig self-node-remediation-config -n "$NS"; then
    clear_finalizers selfnoderemediationconfig self-node-remediation-config -n "$NS"
    wait_for 60 "SNR config gone" absent selfnoderemediationconfig self-node-remediation-config -n "$NS" || fail "SNR config still present"
  fi
fi
wait_for 180 "SNR agent DaemonSet garbage-collected" absent daemonset self-node-remediation-ds -n "$NS" \
  || record 18-delete-snr-ds delete daemonset self-node-remediation-ds -n "$NS" --ignore-not-found --wait=false >/dev/null || true
record 18-delete-snr-template delete selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
record 18-ce-before get clusterextension "$CE_NAME" -o json >/dev/null 2>&1 || true
record 18-delete-clusterextension delete clusterextension "$CE_NAME" --ignore-not-found --wait=false >/dev/null || fail "delete ClusterExtension"
expect "ClusterExtension $CE_NAME gone" wait_for 600 "ClusterExtension gone" absent clusterextension "$CE_NAME" || rc=1
expect "WAO Deployment gone" wait_for 180 "WAO Deployment gone" absent deployment "$WAO_DEPLOYMENT" -n "$NS" || rc=1
```

Section 3 (record leftovers) stays; most lines print nothing because the `ClusterExtension` already removed the CRDs. In section 4, the SNR config, DaemonSet and template steps are now redundant but harmless (`found` guards and `--ignore-not-found`); delete them from section 4 to avoid confusion, keeping the SNR Secret deletion and everything after it.

Replace the catalog deletion lines (`record 18-delete-catalog ...` through `wait_for 120 "catalog ConfigMap gone" ...`) with:

```sh
record 18-delete-clustercatalog delete clustercatalog "$CLUSTERCATALOG" --ignore-not-found --wait=false >/dev/null || fail "delete ClusterCatalog"
wait_for 120 "ClusterCatalog gone" absent clustercatalog "$CLUSTERCATALOG" || fail "ClusterCatalog still present"
for f in 20-clusterrolebinding 10-clusterrole 00-serviceaccount; do
  record "18-delete-installer-$f" delete -f "$OLMV1_DIR/wao/$f.yaml" --ignore-not-found >/dev/null || fail "delete installer $f"
done
```

In section 6, replace `expect "CSV and WAO Deployment gone" absent csv "$CSV_NAME" -n "$NS" || rc=1` with:

```sh
expect "ClusterExtension gone" absent clusterextension "$CE_NAME" || rc=1
```

Update the header comment of the script: "Delete the config, the SNR objects, then the ClusterExtension (which removes the thirteen CRDs and every CR), the installer RBAC, the ClusterCatalog and the namespace."

- [ ] **Step 3: Describe the mutations in `run-all.sh`**

Replace the RUN.md heredoc block in `test/cluster/run-all.sh` with:

```sh
if [ ! -f "$RUN_DIR/RUN.md" ]; then
  cat >"$RUN_DIR/RUN.md" <<'MD'
# WAO POC live-cluster run

Raw output in this directory is git-ignored and may contain cluster-identifying details.

## Intended mutations
- Apply the ClusterCatalog `wao-poc` (FBC image in the internal registry).
- Create namespace `openshift-workload-availability`, the installer ServiceAccount `wao-installer` with its ClusterRole and
  ClusterRoleBinding, and the ClusterExtension `workload-availability-operator` pinned to 0.1.0.
- Enable each of the six components in turn. Enabling SNR starts privileged SNR agents on every eligible node (D3).
- Server dry-run admission probes only. No NodeHealthCheck, StorageBasedRemediationConfig, FenceAgentsRemediation,
  MachineDeletionRemediation, NodeMaintenance or SelfNodeRemediation is ever created.
- Delete the WAO pod (twice), scale the SBR manager to 0 once, disable components, delete the config.

## Cleanup (WAO-INST-18)
- Delete the config and the SNR config, template and Secret (agents stop); delete the ClusterExtension, which removes
  the thirteen CRDs and every remaining CR; delete the installer RBAC, the NHC aggregation role and binding, the
  ConsolePlugin, `medik8s-leases` if present, the ClusterCatalog and the namespace.
- Kept deliberately: the image build namespace `wao-poc-build`.
MD
fi
```

- [ ] **Step 4: Verify offline**

Run: `bash -n test/cluster/18-uninstall.sh && bash -n test/cluster/run-all.sh && ! grep -n 'subscription\|catalogsource\|CAT_NS\|CATALOG_FILE' test/cluster/18-uninstall.sh test/cluster/run-all.sh && make test-offline`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add test/cluster/18-uninstall.sh test/cluster/run-all.sh
git commit -m "wao: WAO-INST-18 uninstalls through the ClusterExtension"
```

---

### Task 11: `full-run.sh build` builds the bundle and catalog images on the cluster

**Files:**
- Modify: `test/cluster/full-run.sh` (`phase_build`, `need_catalog`, `confirm` text, `phase_install` output, header comment)

**Interfaces:**
- Consumes: `make fbc`, `make clustercatalog` (Tasks 3, 6), `catalog.Dockerfile` (Task 5), `bundle.Dockerfile`.
- Produces: BuildConfigs `wao-bundle` and `wao-catalog` in `wao-poc-build`; image-puller grants for `system:serviceaccounts:openshift-catalogd` and `system:serviceaccounts:openshift-operator-controller`; `dist/wao-poc-clustercatalog.yaml`.

The bundle and catalog images are binary Docker builds from staged temporary directories that contain only the Dockerfile and the files it copies. The working tree is never uploaded, so no kubeconfig can leak.

- [ ] **Step 1: Write the failing check**

Run: `grep -q 'wao-catalog' test/cluster/full-run.sh`
Expected: exit 1.

- [ ] **Step 2: Add a binary build helper and the two builds**

In `test/cluster/full-run.sh`, after `oc_long()` add:

```sh
BUNDLE_BC="${BUNDLE_BC:-wao-bundle}"
CATALOG_BC="${CATALOG_BC:-wao-catalog}"

# binary_build NAME DIR : run (creating if needed) the binary Docker BuildConfig NAME in $BUILD_NS from DIR,
# which must contain a Dockerfile and only the files it copies. Prints the image digest reference.
binary_build() {
  local name="$1" dir="$2" digest
  if absent buildconfig "$name" -n "$BUILD_NS"; then
    record "build-new-build-$name" new-build --binary --name "$name" -n "$BUILD_NS" --strategy docker >/dev/null
  fi
  oc_long start-build "$name" -n "$BUILD_NS" --from-dir="$dir" --follow --wait >&2
  digest=$(k get istag "$name:latest" -n "$BUILD_NS" -o jsonpath='{.image.metadata.name}')
  case "$digest" in sha256:*) ;; *) die "no image digest for istag $name:latest in $BUILD_NS (got '$digest')" ;; esac
  echo "${REGISTRY}/${BUILD_NS}/${name}@${digest}"
}
```

In `phase_build`, right after the `digest=$(k get istag wao:latest ...)` line and its `case` check (outside the `SKIP_BUILD` block, so it runs on every build), add:

```sh
  # catalogd unpacks the catalog image and operator-controller unpacks the bundle image, each from its own
  # namespace, so both need pull access to the build namespace (as does the install namespace, granted above).
  record build-image-puller-catalogd policy add-role-to-group system:image-puller \
    system:serviceaccounts:openshift-catalogd -n "$BUILD_NS" >/dev/null
  record build-image-puller-operator-controller policy add-role-to-group system:image-puller \
    system:serviceaccounts:openshift-operator-controller -n "$BUILD_NS" >/dev/null
```

Replace the final `make catalog-configmap DEFAULT_CHANNEL=alpha` line and the `cat <<EOF ... build done` block with:

```sh
  step "build the bundle image in $BUILD_NS"
  stage=$(mktemp -d)
  cp bundle.Dockerfile "$stage/Dockerfile"
  cp -R bundle "$stage/bundle"
  bundle_img=$(binary_build "$BUNDLE_BC" "$stage")
  rm -rf "$stage"
  echo "bundle image: $bundle_img"

  step "render and validate the file-based catalog for $bundle_img"
  make fbc BUNDLE_IMG="$bundle_img"

  step "build the catalog image in $BUILD_NS"
  stage=$(mktemp -d)
  cp catalog.Dockerfile "$stage/Dockerfile"
  mkdir -p "$stage/dist"
  cp -R dist/catalog "$stage/dist/catalog"
  catalog_img=$(binary_build "$CATALOG_BC" "$stage")
  rm -rf "$stage"
  echo "catalog image: $catalog_img"
  make clustercatalog CATALOG_IMG="$catalog_img"
  { echo "- Bundle image: ${bundle_img}"; echo "- Catalog image: ${catalog_img}"; } >> "$RUN_DIR/RUN.md"
  cat <<EOF

######## build done
image   : $img
bundle  : $bundle_img
catalog : $catalog_img -> $CLUSTERCATALOG_FILE
bundle/ : now references the operator image above (git diff -- README.md bundle config/manager)
Next    : bash test/cluster/full-run.sh install   (WAO only)   or   bash test/cluster/full-run.sh run   (all cases)
To commit the bundle update after review (never evidence/):
  git add README.md bundle/manifests/workload-availability-operator.clusterserviceversion.yaml config/manager/kustomization.yaml
  git commit -m "wao: point bundle at rebuilt image ${digest:7:12}" -- README.md bundle config/manager
EOF
```

Replace `need_catalog()` with:

```sh
need_catalog() {
  [ -f "$CLUSTERCATALOG_FILE" ] || die "$CLUSTERCATALOG_FILE missing; run \`bash test/cluster/full-run.sh build\` first"
}
```

In `confirm()`, change "installs WAO through OLM in $NS" to "installs WAO through OLM v1 (ClusterExtension) in $NS" in both the `install` and `run|all` texts. In `phase_install`, replace `k get csv -n "$NS"` with `k get clusterextension "$CE_NAME"`. Update the header comment: the `build` line gains "builds the bundle and catalog images and renders dist/wao-poc-clustercatalog.yaml"; the `install` line reads "WAO-INST-00..02: ClusterCatalog, namespace and installer RBAC, ClusterExtension"; the "`install` and `run` need ..." sentence names `dist/wao-poc-clustercatalog.yaml`.

`SKIP_BUILD=1` reuses the operator image only; the bundle and catalog builds always run, because the bundle changes whenever the operator digest changes.

- [ ] **Step 3: Verify offline**

Run: `bash -n test/cluster/full-run.sh && ! grep -n 'catalog-configmap\|CATALOG_FILE\b\|get csv' test/cluster/full-run.sh && make test-offline && grep -c 'binary_build' test/cluster/full-run.sh`
Expected: syntax ok, no classic references, tests pass, count 3 (definition plus two calls).

Also confirm the harness has no remaining classic references at all:

```sh
grep -n 'CAT_NS\|\$CATALOG\b\|CATALOG_FILE\|catalogsource\|subscription\|operatorgroup\|installplan\|packagemanifest' test/cluster/*.sh; echo "exit $?"
```

Expected: `exit 1` (no matches).

- [ ] **Step 4: Commit**

```bash
git add test/cluster/full-run.sh
git commit -m "wao: full-run build phase produces the bundle and catalog images and the ClusterCatalog"
```

---

### Task 12: Documentation for the OLM v1 install path

**Files:**
- Modify: `README.md` (file table, "Operator image and POC catalog", "Run the POC on a cluster" table and notes, "Install by hand", the uninstall bullets, the status row wording "classic OLM")
- Modify: `TUTORIAL.md` section 9 and the command quick reference
- Modify: `docs/agent-test-run.md` sections 2, 4, 5 and the failure table
- Modify: `test/cluster/README.md` prerequisites and running notes
- Modify: `test/olmv1/README.md` (one paragraph at the top)

**Interfaces:** none; text only. Every statement must match what Tasks 2–11 built. Historical sections (README "Deviations from the plan", "Known upstream issues", the `test/olmv1/` experiment records) keep their classic OLM mentions as history.

- [ ] **Step 1: Write the failing check**

Run:

```sh
grep -n 'catalog-configmap\|configmap-catalog\|dist/wao-poc-catalog.yaml\|installPlanApproval\|openshift-marketplace' README.md TUTORIAL.md docs/agent-test-run.md test/cluster/README.md | wc -l
```

Expected: a positive count.

- [ ] **Step 2: README.md**

Replace the section "## Operator image and POC catalog" with:

````markdown
## Operator image, bundle image and catalog

**Registry choice:** the OpenShift internal image registry of the disposable test cluster. No
external registry credentials are needed. Three images are built there with OpenShift binary
Docker builds in the namespace `wao-poc-build`, not in the install namespace, because preflight
(WAO-INST-00) requires `openshift-workload-availability` to be absent:

| Image | BuildConfig | Built from | Referenced by |
| --- | --- | --- | --- |
| WAO operator | `wao` | `git archive HEAD` (never the working tree) | the bundle CSV, by digest |
| Bundle | `wao-bundle` | `bundle.Dockerfile` + `bundle/` | the FBC `olm.bundle.image`, by digest |
| Catalog | `wao-catalog` | `catalog.Dockerfile` + `dist/catalog/` | the `ClusterCatalog` `wao-poc`, by digest |

`bash test/cluster/full-run.sh build` does all of this (see the next section). By hand:

```sh
KC=/path/to/disposable-cluster.kubeconfig   # always passed explicitly
oc create namespace wao-poc-build --kubeconfig "$KC"
for g in openshift-workload-availability openshift-catalogd openshift-operator-controller; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:$g" -n wao-poc-build --kubeconfig "$KC"
done

# 1. operator image
SRC=$(mktemp -d) && git archive HEAD | tar -x -C "$SRC"
oc new-build --binary --name wao -n wao-poc-build --strategy docker --kubeconfig "$KC"
oc start-build wao -n wao-poc-build --from-dir="$SRC" --follow --kubeconfig "$KC"
IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@$(oc get istag wao:latest -n wao-poc-build --kubeconfig "$KC" -o jsonpath='{.image.metadata.name}')
make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha && make bundle-check

# 2. bundle image
STAGE=$(mktemp -d) && cp bundle.Dockerfile "$STAGE/Dockerfile" && cp -R bundle "$STAGE/bundle"
oc new-build --binary --name wao-bundle -n wao-poc-build --strategy docker --kubeconfig "$KC"
oc start-build wao-bundle -n wao-poc-build --from-dir="$STAGE" --follow --kubeconfig "$KC"
BUNDLE_IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-bundle@$(oc get istag wao-bundle:latest -n wao-poc-build --kubeconfig "$KC" -o jsonpath='{.image.metadata.name}')

# 3. file-based catalog and catalog image
make fbc BUNDLE_IMG=$BUNDLE_IMG                      # dist/catalog/, validated with opm
STAGE=$(mktemp -d) && cp catalog.Dockerfile "$STAGE/Dockerfile" && mkdir "$STAGE/dist" && cp -R dist/catalog "$STAGE/dist/catalog"
oc new-build --binary --name wao-catalog -n wao-poc-build --strategy docker --kubeconfig "$KC"
oc start-build wao-catalog -n wao-poc-build --from-dir="$STAGE" --follow --kubeconfig "$KC"
CATALOG_IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao-catalog@$(oc get istag wao-catalog:latest -n wao-poc-build --kubeconfig "$KC" -o jsonpath='{.image.metadata.name}')
make clustercatalog CATALOG_IMG=$CATALOG_IMG         # dist/wao-poc-clustercatalog.yaml (git-ignored)
```

For an external registry use `make bundle-build bundle-push catalog-build catalog-push` with
`BUNDLE_IMG` and `CATALOG_IMG` set to digest references after the push.

The committed bundle currently references
`image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@sha256:6077f4265aaf49de3e445e07bd7ee1750171951cdc2d7de4a11f7d8f63328671`
(linux/amd64). A different cluster needs its own builds and a regenerated bundle.
````

Keep the digest line exactly as it is in the current README (copy it, do not retype it).

Replace the section "## Install by hand" with:

````markdown
## Install by hand

What `full-run.sh install` does, on a disposable OpenShift 4.18+ cluster with no medik8s operators
or CRDs installed (design brief D11, D12):

1. `oc apply -f dist/wao-poc-clustercatalog.yaml` and wait for the `ClusterCatalog` `wao-poc` to
   report `Serving=True`.
2. `oc apply -f config/olmv1/namespace.yaml` (the namespace with `openshift.io/node-selector: ""`
   and privileged PSA labels), then `oc apply -f config/olmv1/wao/00-serviceaccount.yaml`,
   `10-clusterrole.yaml` and `20-clusterrolebinding.yaml` (installer RBAC; ignored on OpenShift 5.0,
   required on 4.18–4.22).
3. `oc apply -f config/olmv1/wao/30-clusterextension.yaml`. The `ClusterExtension`
   `workload-availability-operator` reaches `Installed=True` with reason `Succeeded`, installs bundle
   `workload-availability-operator.v0.1.0`, and the thirteen CRDs carry the label
   `olm.operatorframework.io/owner-name=workload-availability-operator`.
4. WAO creates the config `cluster` with every component `Disabled` (D4). Enable a component with,
   for example:

   ```sh
   oc patch workloadavailabilityconfig cluster --type merge \
     -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"}}}}'
   ```

**Uninstall:** delete the `WorkloadAvailabilityConfig` first so WAO's finalizer removes the
operands; delete any `SelfNodeRemediationConfig` (its DaemonSet is garbage-collected); then
`oc delete clusterextension workload-availability-operator`. **This deletes all thirteen CRDs and
every remaining custom resource of those kinds.** Then delete the installer RBAC, the
`ClusterCatalog` and the namespace.
````

Update the "Run the POC on a cluster" phase table: the `build` row's "What it does" ends with "`make bundle` pointed at the new digest, bundle and catalog image builds, `make fbc`, `make clustercatalog`" and its "Mutates" column adds "BuildConfigs `wao-bundle`, `wao-catalog`"; the `install` row reads "Cases 00–02: ClusterCatalog, namespace and installer RBAC, ClusterExtension" with "Mutates" reading "ClusterCatalog `wao-poc`; namespace `openshift-workload-availability`; installer RBAC". Replace "a **disposable** OpenShift cluster with classic OLM" with "a **disposable** OpenShift 4.18+ cluster (OLM v1)". Replace the sentence "`install` and `run` need a prior `build` on that cluster (the image in its internal registry and `dist/wao-poc-catalog.yaml`)" with "... (the three images in its internal registry and `dist/wao-poc-clustercatalog.yaml`)". Update the file table: delete the `hack/configmap-catalog.py` row; add rows for `hack/fbc-catalog.py` ("Renders the OLM v1 file-based catalog from `bundle/`"), `hack/clustercatalog.py` ("Renders the `ClusterCatalog` for a catalog image digest"), `catalog.Dockerfile` ("Scratch catalog image, FBC at `/configs`") and `config/olmv1/` ("Namespace, installer RBAC and `ClusterExtension` (generated)"). In the status table, change "(3 nodes, `HighlyAvailable`, classic OLM)" to "(3 nodes, `HighlyAvailable`)" and leave the rest of that history as is. In the uninstall bullet near "Delete the Subscription and the CSV in `openshift-workload-availability`. OLM removes WAO's Deployment; CRDs remain, as with any OLM uninstall." replace with "Delete the ClusterExtension `workload-availability-operator`. OLM v1 removes WAO's Deployment and the thirteen CRDs." and change the adjacent "CatalogSource and its ConfigMap" to "ClusterCatalog".

- [ ] **Step 3: TUTORIAL.md**

Replace the "Regenerate the bundle and render the catalog" bullet in section 9 with:

````markdown
- Regenerate the bundle, then build the bundle and catalog images and render the ClusterCatalog
  (what `bash test/cluster/full-run.sh build` scripts; see README "Operator image, bundle image and catalog"):
  ```sh
  make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
  make bundle-check
  make fbc BUNDLE_IMG=$BUNDLE_IMG                # -> dist/catalog/, validated with opm
  make clustercatalog CATALOG_IMG=$CATALOG_IMG   # -> dist/wao-poc-clustercatalog.yaml
  ```
- Why an FBC image: OLM v1's `ClusterCatalog` accepts only images (design brief D6). catalogd reads
  the directory named by the `operators.operatorframework.io.index.configs.v1` label, so a
  `FROM scratch` image is enough.
````

Add to the gotchas list in section 9: "Both catalogd and operator-controller pull from the build namespace, so grant `system:image-puller` to `system:serviceaccounts:openshift-catalogd` and `system:serviceaccounts:openshift-operator-controller`, not only to the install namespace." In the command quick reference (around line 302) replace `catalog-configmap` with `fbc clustercatalog olmv1-manifests-check`.

- [ ] **Step 4: docs/agent-test-run.md**

Section 2: replace "classic OLM present" with "OLM v1 present (`ClusterExtension` and `ClusterCatalog` APIs, operator-controller Available)". Replace the failure-table row "classic OLM absent" with "OLM v1 absent | The cluster is older than OpenShift 4.18 or has OLM v1 disabled. It cannot be used; report it." Section 4: replace the `make catalog-configmap` command with the bundle image build, `make fbc BUNDLE_IMG=...`, catalog image build and `make clustercatalog CATALOG_IMG=...` lines from the README section above, and say that `full-run.sh build` does them. Section 5: rewrite the 01, 02 and 18 bullets:

```markdown
- 01 applies the ClusterCatalog `wao-poc` and waits for `Serving=True`.
- 02 creates the namespace and installer RBAC and applies the ClusterExtension `workload-availability-operator` pinned to 0.1.0.
- 18 deletes the config and the SNR objects, deletes the ClusterExtension (which removes the thirteen CRDs and every CR),
  then the installer RBAC, ClusterCatalog and namespace. It keeps `wao-poc-build` on purpose and reports it as a `LEFTOVER`.
```

Replace the `make bundle-check && make catalog-configmap DEFAULT_CHANNEL=alpha` line in the command reference near line 285 with `make bundle-check && make fbc BUNDLE_IMG=$BUNDLE_IMG && make clustercatalog CATALOG_IMG=$CATALOG_IMG`.

- [ ] **Step 5: test/cluster/README.md and test/olmv1/README.md**

In `test/cluster/README.md` prerequisites: "A **disposable** OpenShift 4.18 or newer cluster with OLM v1 (default since 4.18) that you are authorized to modify." Replace the `dist/wao-poc-catalog.yaml from make catalog-configmap` bullet with "`dist/wao-poc-clustercatalog.yaml` from `make clustercatalog` (written by `full-run.sh build`)". In the "Running" notes replace "A failed catalog or install (01, 02)" wording only if it names classic objects.

At the top of `test/olmv1/README.md` add:

```markdown
> Since decision D11 the repository installs only through OLM v1 and `test/cluster/` is the
> harness for that. The scripts here remain the record of the experiments (0001–0005) that
> informed it. `gen-installer-rbac.py --only wao` also produces the committed
> `config/olmv1/wao/` manifests (`make olmv1-manifests`).
```

- [ ] **Step 6: Run the check**

Run:

```sh
grep -n 'catalog-configmap\|configmap-catalog\|dist/wao-poc-catalog.yaml\|installPlanApproval\|openshift-marketplace' README.md TUTORIAL.md docs/agent-test-run.md test/cluster/README.md | wc -l
grep -n -i 'subscription\|operatorgroup\|installplan\|catalogsource' README.md TUTORIAL.md docs/agent-test-run.md test/cluster/README.md
```

Expected: `0` from the first command. The second command may only match inside README "Deviations from the plan", "Known upstream issues" and TUTORIAL history lines (such as the uninstall-order note for standalone operators); read each match and confirm it is history, not an instruction. Then `make test-offline` passes.

- [ ] **Step 7: Commit**

```bash
git add README.md TUTORIAL.md docs/agent-test-run.md test/cluster/README.md test/olmv1/README.md
git commit -m "wao: document the OLM v1 install path"
```

---

### Task 13: OpenShift metadata the research marks SHOULD

**Files:**
- Modify: `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml` (annotations)
- Create: `hack/bundle-annotations.py`, `hack/bundle_annotations_test.py`
- Modify: `Makefile` (`bundle` target runs the post-processor; `test-offline` runs the test)
- Modify: `hack/check-bundle.py` and `hack/check_bundle_test.py` (assert the annotations)

**Interfaces:**
- Produces: CSV annotations `features.operators.openshift.io/{disconnected,fips-compliant,proxy-aware,tls-profiles,token-auth-aws,token-auth-azure,token-auth-gcp,cnf,cni,csi}`; `bundle/metadata/annotations.yaml` key `com.redhat.openshift.versions: "v4.18"` and the matching `LABEL` in `bundle.Dockerfile`, re-applied after every `operator-sdk generate bundle`.

The values below are honest for the POC: operand images are pinned by digest and listed in `relatedImages` (`disconnected: "true"`); nothing else is claimed.

- [ ] **Step 1: Write the failing tests**

Create `hack/bundle_annotations_test.py`:

```python
# hack/bundle_annotations_test.py
import pathlib, shutil, subprocess, sys, tempfile, unittest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent


class BundleAnnotationsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        (self.tmp / "bundle" / "metadata").mkdir(parents=True)
        (self.tmp / "bundle" / "metadata" / "annotations.yaml").write_text(yaml.safe_dump(
            {"annotations": {"operators.operatorframework.io.bundle.package.v1": "workload-availability-operator"}}))
        (self.tmp / "bundle.Dockerfile").write_text("FROM scratch\nLABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1\nCOPY bundle/manifests /manifests/\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_it(self):
        return subprocess.run([sys.executable, str(HERE / "bundle-annotations.py"), "--bundle", str(self.tmp / "bundle"),
                               "--dockerfile", str(self.tmp / "bundle.Dockerfile"), "--openshift-versions", "v4.18"],
                              capture_output=True, text=True, check=True)

    def test_adds_versions_annotation_and_label_once(self):
        self.run_it()
        self.run_it()  # idempotent
        ann = yaml.safe_load((self.tmp / "bundle" / "metadata" / "annotations.yaml").read_text())["annotations"]
        self.assertEqual(ann["com.redhat.openshift.versions"], "v4.18")
        self.assertEqual(ann["operators.operatorframework.io.bundle.package.v1"], "workload-availability-operator")
        text = (self.tmp / "bundle.Dockerfile").read_text()
        self.assertEqual(text.count('LABEL com.redhat.openshift.versions="v4.18"'), 1)
        self.assertLess(text.index("LABEL com.redhat.openshift.versions"), text.index("COPY "), "label before COPY lines")


class CommittedBundleTest(unittest.TestCase):
    def setUp(self):
        if not (REPO / "bundle").exists():
            self.skipTest("bundle not generated")

    def test_committed_bundle_carries_openshift_metadata(self):
        ann = yaml.safe_load((REPO / "bundle" / "metadata" / "annotations.yaml").read_text())["annotations"]
        self.assertEqual(ann.get("com.redhat.openshift.versions"), "v4.18")
        self.assertIn('LABEL com.redhat.openshift.versions="v4.18"', (REPO / "bundle.Dockerfile").read_text())
        csv = yaml.safe_load((REPO / "bundle" / "manifests" / "workload-availability-operator.clusterserviceversion.yaml").read_text())
        a = csv["metadata"]["annotations"]
        expected = {"disconnected": "true", "fips-compliant": "false", "proxy-aware": "false", "tls-profiles": "false",
                    "token-auth-aws": "false", "token-auth-azure": "false", "token-auth-gcp": "false",
                    "cnf": "false", "cni": "false", "csi": "false"}
        for key, value in expected.items():
            self.assertEqual(a.get(f"features.operators.openshift.io/{key}"), value, key)


if __name__ == "__main__":
    unittest.main()
```

Run: `.venv/bin/python -m unittest hack/bundle_annotations_test.py -v`
Expected: FAIL (script missing; committed bundle lacks the annotations).

- [ ] **Step 2: Write `hack/bundle-annotations.py`**

```python
#!/usr/bin/env python3
# hack/bundle-annotations.py
"""Add the OpenShift bundle annotation and label that `operator-sdk generate bundle` does not emit.

com.redhat.openshift.versions declares the OpenShift releases the bundle targets (Red Hat
certification policy syntax: "v4.18" is open-ended from 4.18). Written to
bundle/metadata/annotations.yaml and as a LABEL in bundle.Dockerfile, before the COPY lines.
Idempotent: safe to run after every `make bundle`.
"""
import argparse, pathlib
import yaml

KEY = "com.redhat.openshift.versions"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", default="bundle")
    ap.add_argument("--dockerfile", default="bundle.Dockerfile")
    ap.add_argument("--openshift-versions", required=True, help='e.g. "v4.18" or "v4.18-v4.22"')
    a = ap.parse_args()

    ann_path = pathlib.Path(a.bundle, "metadata", "annotations.yaml")
    doc = yaml.safe_load(ann_path.read_text())
    doc["annotations"][KEY] = a.openshift_versions
    ann_path.write_text(yaml.safe_dump(doc, sort_keys=False, width=4096))

    df = pathlib.Path(a.dockerfile)
    lines = [l for l in df.read_text().splitlines() if not l.startswith(f"LABEL {KEY}=")]
    label = f'LABEL {KEY}="{a.openshift_versions}"'
    first_copy = next((i for i, l in enumerate(lines) if l.startswith("COPY ")), len(lines))
    lines.insert(first_copy, label)
    df.write_text("\n".join(lines) + "\n")
    print(f"{KEY}={a.openshift_versions} written to {ann_path} and {df}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Add the CSV annotations and the Makefile hook**

In `config/manifests/bases/workload-availability-operator.clusterserviceversion.yaml`, under `metadata.annotations`, add:

```yaml
    features.operators.openshift.io/disconnected: "true"
    features.operators.openshift.io/fips-compliant: "false"
    features.operators.openshift.io/proxy-aware: "false"
    features.operators.openshift.io/tls-profiles: "false"
    features.operators.openshift.io/token-auth-aws: "false"
    features.operators.openshift.io/token-auth-azure: "false"
    features.operators.openshift.io/token-auth-gcp: "false"
    features.operators.openshift.io/cnf: "false"
    features.operators.openshift.io/cni: "false"
    features.operators.openshift.io/csi: "false"
```

In the Makefile, add `OPENSHIFT_VERSIONS ?= v4.18` near `VERSION`, and append to the `bundle` target recipe, before `$(OPERATOR_SDK) bundle validate ./bundle`:

```makefile
	$(PYTHON) hack/bundle-annotations.py --bundle bundle --dockerfile bundle.Dockerfile --openshift-versions $(OPENSHIFT_VERSIONS)
```

Append `hack/bundle_annotations_test.py` to the unittest line of `test-offline`.

- [ ] **Step 4: Regenerate the bundle without changing the image**

Run (the image must stay the committed one; copy it from the CSV):

```sh
IMG=$(grep -m1 -Eo 'image: image-registry\.openshift-image-registry\.svc:5000/[^ ]+' bundle/manifests/workload-availability-operator.clusterserviceversion.yaml | sed 's/^image: //')
make bundle IMG="$IMG" VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
git diff --stat
```

Expected: changes only in the CSV (ten new annotations and `createdAt`), `bundle/metadata/annotations.yaml` (one new key) and `bundle.Dockerfile` (one new `LABEL`). If `config/manager/kustomization.yaml` changed, the image differed; restore it with `git checkout -- config/manager/kustomization.yaml` and redo with the right `IMG`.

- [ ] **Step 5: Assert the annotations in `check-bundle.py`**

In `olmv1_problems()` (Task 4) add before `return problems`:

```python
    annotations = csv["metadata"].get("annotations", {})
    missing = [k for k in ("disconnected", "fips-compliant", "proxy-aware", "tls-profiles", "token-auth-aws",
                           "token-auth-azure", "token-auth-gcp", "cnf", "cni", "csi")
               if f"features.operators.openshift.io/{k}" not in annotations]
    if missing:
        problems.append(f"CSV lacks features.operators.openshift.io annotations: {missing}")
    bundle_ann = yaml.safe_load((meta / "annotations.yaml").read_text())["annotations"]
    if "com.redhat.openshift.versions" not in bundle_ann:
        problems.append("metadata/annotations.yaml lacks com.redhat.openshift.versions (run make bundle)")
```

Add to `hack/check_bundle_test.py`:

```python
    def test_missing_feature_annotation_rejected(self):
        del self.csv["metadata"]["annotations"]["features.operators.openshift.io/disconnected"]
        self.save()
        proc = check(self.bundle)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("features.operators.openshift.io", proc.stdout)
```

- [ ] **Step 6: Run everything**

Run: `make bundle-check olmv1-manifests-check test-offline`
Expected: `bundle OK ...`; `config/olmv1/wao is current` (if the diff shows only a header change, run `make olmv1-manifests` and include it in the commit); all tests pass, including the new `CommittedBundleTest`.

- [ ] **Step 7: Commit**

```bash
git add config/manifests/bases bundle bundle.Dockerfile hack/bundle-annotations.py hack/bundle_annotations_test.py hack/check-bundle.py hack/check_bundle_test.py Makefile config/olmv1
git commit -m "wao: declare OpenShift feature annotations and target versions in the bundle"
```

---

### Task 14: Live verification on a confirmed disposable cluster

**Files:**
- No source changes expected. Evidence under `evidence/<UTC-date>-wao-poc-olmv1/` (git-ignored). A sanitized `REPORT.md` may be copied under `docs/results/` only after review.

**Interfaces:**
- Consumes: everything above.
- Produces: `results.json` with 19 `pass` entries.

Preconditions: the person you work for has confirmed, in this session, which disposable cluster to use and that it may be mutated. The cluster is OpenShift 4.18 or newer with OLM v1; `linux/amd64` nodes; a topology NHC supports; no medik8s CRDs. `KUBECONFIG` points at it; `.venv` exists. Read `AGENTS.md` "Cluster work" first.

- [ ] **Step 1: Full run**

```sh
export KUBECONFIG=/path/to/confirmed-disposable.kubeconfig
export RUN_DIR="$PWD/evidence/$(date -u +%F)-wao-poc-olmv1"
CONFIRM=yes bash test/cluster/full-run.sh all
```

Expected: `build` ends with `build done` and prints the operator, bundle and catalog image digests; `run` ends with `19 pass, 0 fail, 0 blocked`. If WAO-INST-02 times out, read `evidence/.../raw/*02-clusterextension-timeout.json` for the `Progressing` message before changing anything: an RBAC `forbidden` message on 4.18–4.22 means `config/olmv1/wao/10-clusterrole.yaml` lacks a rule the bundle renders; fix the generator, `make olmv1-manifests`, commit, run `bash test/cluster/run-all.sh 18`, then rerun.

- [ ] **Step 2: Confirm the cluster is clean and the preflight passes again**

```sh
bash test/cluster/run-all.sh 00
```

Expected: `Preflight passed.`; the note line reports whether `spec.serviceAccount` is `required` (4.18–4.22) or `ignored` (5.0).

- [ ] **Step 3: Review the report and record the outcome**

Read `evidence/.../REPORT.md`; its sanitization check must print `clean`. Fill in the Deviations section. Record the OpenShift version and result in the README "Live install verification" status row (one sentence; no cluster identifiers). If the bundle CSV image digest changed during `build`, commit it as the build output instructs.

- [ ] **Step 4: Commit**

```bash
git add README.md bundle/manifests/workload-availability-operator.clusterserviceversion.yaml config/manager/kustomization.yaml
git commit -m "wao: record the OLM v1 live run and point the bundle at the rebuilt image"
```

Never add `evidence/`.

---

## 4. Self-review notes

**Spec coverage.** Every MUST row of the research checklist maps to a task: registry+v1 shape and AllNamespaces (existing bundle, guarded by Task 4), no dependencies/APIServices/webhookdefinitions (Task 4), semver version (Task 4), catalog image label and `Image` source (Tasks 5, 6), FBC package/channel/bundle and `opm validate` (Task 3), pre-created namespace (Tasks 6, 9), installer RBAC (Tasks 6, 9), pinned `ClusterExtension` with selector (Tasks 6, 9), CRD upgrade safety (no second version in scope; noted out of scope), single-owner precondition (preflight, Task 7), pull access for catalogd and operator-controller (Task 11), CRD-deletion warning in docs (Task 12). SHOULD rows covered: `olm.csv.metadata` property (Task 3), scratch catalog image (Task 5), feature annotations and `com.redhat.openshift.versions` (Task 13), related images by digest (existing, asserted in Task 3), validation commands (Tasks 3, 4). SHOULD rows deliberately deferred: `1.0.0` versioning and RBAC tightening after first install. Classic OLM removal: code and target (Task 2), harness (Tasks 7–11, each with a grep that must come back empty), docs (Task 12), decision record (Task 1).

**Type consistency.** Names used across tasks: `CLUSTERCATALOG`, `CLUSTERCATALOG_FILE`, `CE_NAME`, `OLMV1_DIR` (env.sh, Task 7) are consumed verbatim in Tasks 8–11; `ce_installed`, `ce_progressing_succeeded`, `ce_installed_bundle`, `catalog_serving`, `ce_sa_required`, `olmv1_present` (olmv1.sh) are the only OLM v1 predicates called; `make fbc`, `make clustercatalog`, `make olmv1-manifests(-check)`, `make catalog-build` are the only new targets referenced in scripts and docs; `binary_build NAME DIR` prints the digest reference consumed by `make fbc BUNDLE_IMG=` and `make clustercatalog CATALOG_IMG=`. `CSV_NAME` keeps its current value and is compared with `status.install.bundle.name`.

**Review Focus pins.** 1 → Task 7 `ce_sa_required` and Task 9's comment and `record` of the apply; 2 → Task 3 `test_rejects_tag_reference`; 3 → Task 10 deletion order with bounded waits; 4 → Task 5 `test_catalog_dockerfile_serves_configs`; 5 → Task 7's first preflight `expect`, which names the two CRDs.

**Known open points the live run must settle** (from the research note's open questions): whether the internal-registry pull grants are enough on a cluster whose global pull secret does not cover the internal registry (experiments 0003 and 0004 say yes on 4.22 and 5.0 ec.5); whether a `ClusterExtension` deletion blocked by a CR finalizer surfaces within the 600 s wait (Task 10 records leftovers either way).
