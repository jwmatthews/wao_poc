# OADP-style operand manifests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python operand pipeline with OADP's copy-from-checkout pattern, move operand RBAC into the WAO CSV so OLM owns it, and install from a file-based catalog image.

**Architecture:** Each operand's upstream `config/` tree is copied at a recorded commit into `config/operands/<k>/upstream/`. Two hand-written kustomize overlays per operand sit next to it: `rbac/` feeds operator-sdk's CSV generation (folded via `--extra-service-accounts`), `runtime/` renders the Deployment, Services, ConfigMaps and webhook configurations that the Go renderer embeds and applies at enable time. Discovery of versions, digests and commits is a bash script; copying is a bash script; rendering and verification are Make plus `yq`. The controller stops creating RBAC.

**Tech Stack:** GNU Make, bash, kustomize v5 (`bin/kustomize`), yq v4, operator-sdk v1.42, opm, skopeo, `go version -m`, Go 1.24 with controller-runtime and envtest, OpenShift binary builds for images.

**Spec:** `docs/operand-manifests-oadp-approach-issues.md` (filed as GitHub issues #12 to #16), with evidence in `docs/operand-manifests-oadp-approach.md`. HANDOFF.md holds the decisions.

## Global Constraints

- Do not modify, fork or rebuild component operators. Consume upstream images by digest exactly as pinned in `release-set.yaml`.
- Every component defaults to `Disabled`. Install creates no remediation policy, request, config or agent.
- Never change a component webhook `failurePolicy`.
- WAO never adopts a foreign object; the `guardForeign` check in the controller stays.
- No public API field may override a component image.
- The Go renderer keeps creating Deployment, Service, ConfigMap and webhook configurations at enable time. Only RBAC moves to OLM.
- Operand ServiceAccounts, Roles and bindings exist from install onward, even while every component is Disabled.
- Do not push to GitHub or edit GitHub issues. Local commits only.
- Cluster work only against `/Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig`, passed explicitly on every command as `--kubeconfig`. The shell's ambient `KUBECONFIG` is a relative path that must never be relied on.
- Never capture Secret values. Never create a real NodeHealthCheck, StorageBasedRemediationConfig, NodeMaintenance or remediation request (SNR, SBR, FAR, MDR).
- Run `make test` and `make test-offline` before each commit. `make test` needs the KI-6 workaround (Task 0).
- Small commits, one per task, message ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Checkouts live in `.cache/operands/<k>` (git-ignored). `OPERAND_SRC_DIR` or `<K>_PATH` (`NHC_PATH`, `SNR_PATH`, `SBR_PATH`, `FAR_PATH`, `MDR_PATH`, `NMO_PATH`) override. Never run `git checkout` inside a user-supplied checkout; read objects with `git archive <commit>`.
- Copied files live under `config/operands/<k>/`. Component keys: `nhc snr sbr far mdr nmo`.
- CI never runs the network sync. CI runs `make verify-operand-manifests`, which is offline.

## Review Focus

1. **A ServiceAccount missing from `OPERAND_SERVICE_ACCOUNTS`** silently turns its Roles into standalone bundle files. Expected: `make verify-operand-manifests` fails naming the SA. Pinned in Task 9.
2. **An image whose binary embeds a commit different from the recorded one** (tag moved, or `checkout_ref` used upstream). Expected: `update-release-set` records the embedded commit, and `verify-operand-manifests` fails when the stamp and `release-set.yaml` disagree. Pinned in Tasks 4 and 9.
3. **An upstream Deployment that already mounts a cert volume** (NMO names it `cert`). Expected: one volume at `/tmp/k8s-webhook-server/serving-certs`, pointing at `<prefix>-webhook-server-cert`, never two volumes on one mount path. Pinned in Task 6 (NMO patch targets the existing volume) and Task 7 renderer test.
4. **A Service selector that matches another operand's pods** (MDR's metrics Service, `control-plane: controller-manager` only). Expected: every rendered Service selector carries `workloadavailability.medik8s.io/component=<key>` and every pod template carries the same label. Pinned in Task 7.
5. **Enabling a component after install must not create RBAC and must not fail because RBAC is absent.** Expected: the controller applies zero RBAC kinds, and on the cluster the operand pod starts with the OLM-created ServiceAccount. Pinned in Task 10 (envtest) and Task 15 (cluster).

---

## File Structure

| Path | Responsibility |
|---|---|
| `release-set.yaml` | Per component: `repo`, `version` (display label, e.g. `v5.8.0`), `tag` (the image tag resolved: `latest` or a `vX.Y.Z` tag), `commit`, `images.<ENV>.{upstream,pinned}`. Fields `source` and `bundle` are removed; `resolvedAt` is kept and rewritten. |
| `hack/update-release-set.sh` | Network discovery: resolve tag, digest, embedded commit; rewrite `release-set.yaml`. |
| `hack/update-operand-manifests.sh` | Network: clone or fetch checkouts, `git archive <commit> config` into `config/operands/<k>/upstream/`, write `UPSTREAM.yaml`, then `make operand-manifests`. |
| `hack/verify-operand-manifests.sh` | Offline CI checks over committed files and a fresh `make operand-manifests` run. |
| `hack/image-commit.sh` | Helper: print the Go `version.GitCommit` embedded in an image's binary. Used by `update-release-set.sh`; also useful by hand. |
| `config/operands/<k>/UPSTREAM.yaml` | Stamp: repo, version, commit. |
| `config/operands/<k>/upstream/config/` | Verbatim copy of upstream `config/` at the commit, minus `samples`, `scorecard`, `manifests*`, `assets`. |
| `config/operands/<k>/rbac/kustomization.yaml` | Hand-written: upstream `namePrefix`, resources `../upstream/config/rbac`, deletes the metrics Service. Consumed by `config/manifests`. |
| `config/operands/<k>/runtime/kustomization.yaml` (+ patch files) | Hand-written: `namespace: __WAO_NAMESPACE__`, resources `../upstream/config/default`, `images`, component labels on pod templates and Service selectors, service-ca patches. Built by `make operand-manifests`. |
| `config/operands/crd/kustomization.yaml` | Generated list of the twelve operand CRD files under `../<k>/upstream/config/crd/bases/`. Referenced from `config/crd/kustomization.yaml`. |
| `config/manifests/kustomization.yaml` | Adds `../operands/<k>/rbac` for the six operands. |
| `config/rbac/` | `operand_union_role.yaml` deleted; `role.yaml` regenerated without RBAC verbs. |
| `internal/operands/manifests/<k>/objects.yaml` | Generated multi-document runtime manifests (Deployment, Service, ConfigMap, webhook configurations). `provenance.json` and the per-object files are deleted. |
| `internal/operands/embed.go`, `render.go` | `Load` splits one multi-document file; RBAC kinds removed from `kindOrder`. |
| `internal/components/*.go` | `Original` image references equal `release-set.yaml` `upstream` values. |
| `internal/controller/workloadavailabilityconfig_controller.go` | RBAC kubebuilder markers dropped; comments updated. |
| `config/catalog/catalogsource.yaml`, `config/catalog/subscription.yaml` | Committed templates for the FBC install; image filled by `make catalog-source`. |
| `hack/cluster-build.sh`, `hack/cluster-install.sh`, `hack/cluster-uninstall.sh` | Disposable-cluster flow: on-cluster binary builds of operator, bundle and catalog images; CatalogSource plus Subscription install; teardown. |
| `Makefile` | Targets `update-release-set`, `update-operand-manifests`, `operand-manifests`, `verify-operand-manifests`, `bump-operands`, `catalog-fbc`, `catalog-source`; Python targets removed. |
| `.github/workflows/test.yml` | Python steps removed; runs `make verify-operand-manifests test-offline test`. |

---

### Task 0: Working tree and tooling baseline

**Files:**
- Create: `evidence/go.mod` (git-ignored, temporary, see KI-6)
- Create: `bin/controller-gen-wrapper` (git-ignored)

The repo's `go list ./...` and `controller-gen paths=./...` descend into the git-ignored `evidence/` tree, which contains foreign Go test suites, so `make test` fails in place. The documented workaround is two files. Both stay out of git.

- [ ] **Step 1: Confirm the failure**

Run: `cd /Users/jmatthews/git/jwmatthews/wao_poc && go list ./... 2>&1 | head -2`
Expected: errors mentioning `evidence/...`.

- [ ] **Step 2: Add the nested module sentinel**

```bash
printf 'module evidence\n\ngo 1.24\n' > evidence/go.mod
```

- [ ] **Step 3: Add the controller-gen wrapper**

```bash
make controller-gen
cat > bin/controller-gen-wrapper <<'EOF'
#!/bin/bash
# KI-6: keep controller-gen out of the git-ignored evidence/ tree.
args=()
for a in "$@"; do
  if [ "$a" = 'paths="./..."' ] || [ "$a" = 'paths=./...' ]; then
    args+=('paths=./api/...;./cmd/...;./internal/...')
  else
    args+=("$a")
  fi
done
exec "$(dirname "$0")/controller-gen" "${args[@]}"
EOF
chmod +x bin/controller-gen-wrapper
touch -t 203001010000 bin/controller-gen-wrapper
```

- [ ] **Step 4: Verify `make test` passes with the wrapper**

Run: `make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -15`
Expected: `ok  github.com/medik8s/workload-availability-operator/internal/controller` and `verify-no-changes` clean. If `verify-no-changes` reports a dirty tree from `bundle-reset`, inspect with `git status --short`; the only acceptable diff is none.

Every later `make test` in this plan is run as `make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes` (variables on the make command line, because the Makefile assigns them with `=`; `verify-no-changes` is skipped because it fails on pre-existing untracked files), followed by `git status --short` to confirm no tracked file changed unexpectedly.

- [ ] **Step 5: Download the pinned tools once**

Run: `make kustomize yq operator-sdk opm && ls bin/kustomize bin/yq bin/operator-sdk/*/operator-sdk bin/opm/*/opm`
Expected: four binaries listed.

- [ ] **Step 6: Commit the design docs**

```bash
git add docs/operand-manifests-oadp-approach.md docs/operand-manifests-oadp-approach-issues.md HANDOFF.md docs/superpowers/plans/2026-10-16-oadp-operand-manifests.md
git commit -m "docs: record the OADP-style operand manifest design and plan

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Phase 1: FBC dev catalog (sub-issue #14)

### Task 1: `catalog-fbc` renders the local bundle directory into a validated FBC

**Files:**
- Modify: `Makefile` (the `catalog-build` block, around lines 476 to 523)

**Interfaces:**
- Produces: `make catalog-fbc BUNDLE_IMG=<ref>` writes `catalog/index.yaml` and `catalog.Dockerfile`; `make catalog-build` builds `$(CATALOG_IMG)` from them with `$(CONTAINER_TOOL)`.

The existing `catalog-build` runs `opm render $(BUNDLE_IMG)`, which pulls the bundle image. The on-cluster flow cannot pull from the internal registry on a workstation, so render the local `./bundle` directory instead and stamp the bundle image reference into the rendered blob.

- [ ] **Step 1: Write the failing check**

Run:
```bash
make opm
BUNDLE_IMG=example.test/wao-bundle@sha256:0000000000000000000000000000000000000000000000000000000000000000 make catalog-fbc 2>&1 | tail -3
```
Expected: `No rule to make target 'catalog-fbc'`.

- [ ] **Step 2: Replace the catalog block in the Makefile**

Replace everything from `# Build a file-based catalog image` through the end of `catalog-push` with:

```make
# File-based catalog (FBC). https://olm.operatorframework.io/docs/reference/file-based-catalogs/
# catalog-fbc renders the local ./bundle directory, so it needs no registry access, and stamps
# BUNDLE_IMG into the olm.bundle blob: that is the reference OLM pulls at install time.
# NOTE: CATALOG_DIR and CATALOG_DOCKERFILE are left in place if a recipe fails, for inspection.
CATALOG_DIR := catalog
CATALOG_DOCKERFILE := ${CATALOG_DIR}.Dockerfile
CATALOG_INDEX := $(CATALOG_DIR)/index.yaml

.PHONY: catalog-fbc
catalog-fbc: opm yq verify-previous-version verify-skip-range ## Render ./bundle into a validated FBC under catalog/ for BUNDLE_IMG.
	rm -rf ${CATALOG_DIR} ${CATALOG_DOCKERFILE}
	mkdir -p ${CATALOG_DIR}
	$(OPM) generate dockerfile ${CATALOG_DIR}
	$(OPM) init ${OPERATOR_NAME} --default-channel=${DEFAULT_CHANNEL} --description=./README.md --icon="${BLUE_ICON_PATH}" --output yaml > ${CATALOG_INDEX}
	$(OPM) render ./bundle --output yaml | $(YQ) '(select(.schema == "olm.bundle") | .image) = "$(BUNDLE_IMG)"' >> ${CATALOG_INDEX}
	@for channel in $(shell echo ${CHANNELS} | tr ',' ' '); do \
		printf '%s\n' '---' 'schema: olm.channel' 'package: ${OPERATOR_NAME}' "name: $$channel" 'entries:' '  - name: ${OPERATOR_NAME}.v${VERSION}' >> ${CATALOG_INDEX}; \
		if [ -n "${PREVIOUS_VERSION}" ]; then printf '%s\n' '    replaces: ${OPERATOR_NAME}.v${PREVIOUS_VERSION}' >> ${CATALOG_INDEX}; fi; \
		if [ -n "${SKIP_RANGE_LOWER}" ]; then printf '%s\n' "    skipRange: '>=${SKIP_RANGE_LOWER} <${VERSION}'" >> ${CATALOG_INDEX}; fi; \
	done
	$(OPM) validate ${CATALOG_DIR}
	@test "$$($(YQ) 'select(.schema == "olm.bundle") | .image' ${CATALOG_INDEX})" = "$(BUNDLE_IMG)" || { echo "catalog-fbc: bundle image not stamped"; exit 1; }

.PHONY: catalog-build
catalog-build: catalog-fbc ## Build the FBC image CATALOG_IMG from catalog/ (needs CONTAINER_TOOL).
	$(CONTAINER_TOOL) build . -f ${CATALOG_DOCKERFILE} -t ${CATALOG_IMG}

.PHONY: catalog-push
catalog-push: ## Push the catalog image.
	$(CONTAINER_TOOL) push $(CATALOG_IMG)
```

Also add `catalog/` and `catalog.Dockerfile` to `.gitignore` under the `dist/` line.

- [ ] **Step 3: Run the check**

Run the Step 1 command again.
Expected: `opm validate` succeeds silently and the stamped image check passes. `yq 'select(.schema == "olm.bundle") | .image' catalog/index.yaml` prints the example reference. `ls catalog.Dockerfile catalog/index.yaml` lists both.

- [ ] **Step 4: Verify `opm render` of the directory carried the standalone-object capability**

Run: `yq 'select(.schema == "olm.bundle") | .properties[] | select(.type == "olm.bundle.object") | .type' catalog/index.yaml | sort | uniq -c`
Expected: a count of `olm.bundle.object` entries equal to the number of files in `bundle/manifests` (14 today). This proves FBC carries every bundle file, including future standalone ClusterRoles.

- [ ] **Step 5: Commit**

```bash
git add Makefile .gitignore
git commit -m "build: render the local bundle into a file-based catalog

catalog-fbc renders ./bundle with opm and stamps BUNDLE_IMG into the
olm.bundle blob, so no registry pull is needed to build the catalog.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Committed CatalogSource and Subscription templates, `catalog-source` target

**Files:**
- Create: `config/catalog/catalogsource.yaml`
- Create: `config/catalog/subscription.yaml`
- Modify: `Makefile` (after `catalog-push`)

**Interfaces:**
- Produces: `make catalog-source CATALOG_IMG=<ref>` writes `dist/catalogsource.yaml` (git-ignored) with the image filled in; `config/catalog/subscription.yaml` is applied as is.

- [ ] **Step 1: Write the templates**

`config/catalog/catalogsource.yaml`:
```yaml
# POC catalog for the disposable-cluster install. `make catalog-source CATALOG_IMG=<ref>` fills
# spec.image and writes dist/catalogsource.yaml. The image is a file-based catalog built by
# `make catalog-fbc` (see README, "Operator image and POC catalog").
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: wao-poc-catalog
  namespace: openshift-marketplace
spec:
  displayName: WAO POC
  publisher: medik8s POC
  sourceType: grpc
  image: CATALOG_IMG_PLACEHOLDER
  grpcPodConfig:
    securityContextConfig: restricted
  updateStrategy:
    registryPoll:
      interval: 10m
```

`config/catalog/subscription.yaml`:
```yaml
# Namespace, OperatorGroup and Subscription for the POC install. Every component starts Disabled.
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  annotations:
    openshift.io/node-selector: ""
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: workload-availability
  namespace: openshift-workload-availability
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: workload-availability-operator
  namespace: openshift-workload-availability
spec:
  channel: stable
  name: workload-availability-operator
  source: wao-poc-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

- [ ] **Step 2: Add the Make target**

```make
.PHONY: catalog-source
catalog-source: yq ## Write dist/catalogsource.yaml pointing at CATALOG_IMG.
	@test -n "$(CATALOG_IMG)" || { echo "catalog-source: set CATALOG_IMG"; exit 1; }
	mkdir -p dist
	$(YQ) '.spec.image = "$(CATALOG_IMG)"' config/catalog/catalogsource.yaml > dist/catalogsource.yaml
	@grep -q CATALOG_IMG_PLACEHOLDER dist/catalogsource.yaml && { echo "catalog-source: placeholder left"; exit 1; } || true
```

- [ ] **Step 3: Verify**

Run: `make catalog-source CATALOG_IMG=example.test/wao-catalog@sha256:1111111111111111111111111111111111111111111111111111111111111111 && yq '.spec.image, .spec.sourceType' dist/catalogsource.yaml && KC=/Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig; oc --kubeconfig=$KC apply --dry-run=server -f dist/catalogsource.yaml -f config/catalog/subscription.yaml`
Expected: the example image and `grpc`; the server-side dry run reports all four objects created or configured (dry run) with no validation error.

- [ ] **Step 4: Commit**

```bash
git add config/catalog Makefile
git commit -m "build: committed CatalogSource and Subscription for the FBC install

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Disposable-cluster scripts for on-cluster image builds and install

**Files:**
- Create: `hack/cluster-build.sh`
- Create: `hack/cluster-install.sh`
- Create: `hack/cluster-uninstall.sh`

**Interfaces:**
- Consumes: `make bundle IMG=...`, `make bundle-update`, `make catalog-fbc BUNDLE_IMG=...`, `make catalog-source CATALOG_IMG=...`.
- Produces: `hack/cluster-build.sh KUBECONFIG` prints `IMG`, `BUNDLE_IMG`, `CATALOG_IMG` digests and leaves `dist/catalogsource.yaml`. `hack/cluster-install.sh KUBECONFIG` applies the catalog, namespace, OperatorGroup and Subscription and waits for the CSV. `hack/cluster-uninstall.sh KUBECONFIG` removes them.

The cluster already has binary BuildConfigs `wao`, `wao-bundle` and `wao-catalog` in namespace `wao-poc-build` from an earlier experiment; the script creates them when absent.

- [ ] **Step 1: Write `hack/cluster-build.sh`**

```bash
#!/usr/bin/env bash
# Build the WAO operator, bundle and FBC catalog images on a disposable OpenShift cluster with
# binary Docker builds, then point the bundle and dist/catalogsource.yaml at the digests.
# Usage: hack/cluster-build.sh /path/to/kubeconfig
# The kubeconfig is always passed explicitly; the current context is never used.
set -euo pipefail
KC=${1:?usage: $0 KUBECONFIG}
BUILD_NS=${BUILD_NS:-wao-poc-build}
INSTALL_NS=${INSTALL_NS:-openshift-workload-availability}
REG=image-registry.openshift-image-registry.svc:5000
VERSION=${VERSION:-$(sed -n 's/^DEFAULT_VERSION := //p' Makefile)}
oc() { command oc --kubeconfig="$KC" "$@"; }
cd "$(git rev-parse --show-toplevel)"

echo "cluster: $(oc whoami --show-server)"
oc get namespace "$BUILD_NS" >/dev/null 2>&1 || oc create namespace "$BUILD_NS"
for who in "system:serviceaccounts:$INSTALL_NS" system:serviceaccounts:openshift-marketplace; do
  oc policy add-role-to-group system:image-puller "$who" -n "$BUILD_NS" >/dev/null
done
ensure_bc() { oc get bc "$1" -n "$BUILD_NS" >/dev/null 2>&1 || oc new-build --binary --name "$1" -n "$BUILD_NS" --strategy docker >/dev/null; }
digest_of() { oc get istag "$1:latest" -n "$BUILD_NS" -o jsonpath='{.image.metadata.name}'; }

# 1. Operator image from a clean archive of HEAD (never the working tree).
ensure_bc wao
SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
git archive HEAD | tar -x -C "$SRC"
oc start-build wao -n "$BUILD_NS" --from-dir="$SRC" --follow >/dev/null
IMG="$REG/$BUILD_NS/wao@$(digest_of wao)"
echo "IMG=$IMG"

# 2. Bundle pointed at the operator digest.
make bundle IMG="$IMG" VERSION="$VERSION"
make bundle-update VERSION="$VERSION"
ensure_bc wao-bundle
BSRC=$(mktemp -d); mkdir -p "$BSRC/bundle"
cp -R bundle/manifests bundle/metadata bundle/tests "$BSRC/bundle/"; cp bundle.Dockerfile "$BSRC/Dockerfile"
oc start-build wao-bundle -n "$BUILD_NS" --from-dir="$BSRC" --follow >/dev/null; rm -rf "$BSRC"
BUNDLE_IMG="$REG/$BUILD_NS/wao-bundle@$(digest_of wao-bundle)"
echo "BUNDLE_IMG=$BUNDLE_IMG"

# 3. FBC catalog referencing the bundle digest.
make catalog-fbc BUNDLE_IMG="$BUNDLE_IMG" VERSION="$VERSION"
ensure_bc wao-catalog
CSRC=$(mktemp -d); cp -R catalog "$CSRC/catalog"; cp catalog.Dockerfile "$CSRC/Dockerfile"
oc start-build wao-catalog -n "$BUILD_NS" --from-dir="$CSRC" --follow >/dev/null; rm -rf "$CSRC"
CATALOG_IMG="$REG/$BUILD_NS/wao-catalog@$(digest_of wao-catalog)"
echo "CATALOG_IMG=$CATALOG_IMG"
make catalog-source CATALOG_IMG="$CATALOG_IMG"
echo "wrote dist/catalogsource.yaml; next: hack/cluster-install.sh $KC"
```

Note: `opm generate dockerfile catalog` writes `catalog.Dockerfile` with `ADD catalog /configs`, so the build context needs the directory named `catalog` beside the Dockerfile. The script preserves that.

- [ ] **Step 2: Write `hack/cluster-install.sh`**

```bash
#!/usr/bin/env bash
# Install WAO through classic OLM from the FBC CatalogSource written by hack/cluster-build.sh.
# Usage: hack/cluster-install.sh /path/to/kubeconfig
set -euo pipefail
KC=${1:?usage: $0 KUBECONFIG}
NS=openshift-workload-availability
oc() { command oc --kubeconfig="$KC" "$@"; }
cd "$(git rev-parse --show-toplevel)"
test -f dist/catalogsource.yaml || { echo "dist/catalogsource.yaml missing; run hack/cluster-build.sh first"; exit 1; }

oc apply -f dist/catalogsource.yaml
for _ in $(seq 1 60); do
  state=$(oc get catalogsource wao-poc-catalog -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  [ "$state" = READY ] && break; sleep 5
done
[ "$state" = READY ] || { echo "CatalogSource not READY (state=$state)"; oc get pods -n openshift-marketplace -l olm.catalogSource=wao-poc-catalog; exit 1; }

oc apply -f config/catalog/subscription.yaml
for _ in $(seq 1 60); do
  csv=$(oc get subscription workload-availability-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  [ -n "$csv" ] && phase=$(oc get csv "$csv" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "${phase:-}" = Succeeded ] && break; sleep 5
done
[ "${phase:-}" = Succeeded ] || { echo "CSV not Succeeded (csv=$csv phase=${phase:-})"; oc get sub,ip,csv -n "$NS"; exit 1; }
echo "installed $csv"
oc get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name}={.phase}{"\n"}{end}' 2>/dev/null || true
```

- [ ] **Step 3: Write `hack/cluster-uninstall.sh`**

```bash
#!/usr/bin/env bash
# Remove the WAO install created by hack/cluster-install.sh. Leaves the build namespace alone.
# Usage: hack/cluster-uninstall.sh /path/to/kubeconfig
set -euo pipefail
KC=${1:?usage: $0 KUBECONFIG}
NS=openshift-workload-availability
oc() { command oc --kubeconfig="$KC" "$@"; }
oc delete workloadavailabilityconfig cluster --ignore-not-found --timeout=120s || true
csv=$(oc get subscription workload-availability-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
oc delete subscription workload-availability-operator -n "$NS" --ignore-not-found
[ -n "$csv" ] && oc delete csv "$csv" -n "$NS" --ignore-not-found
oc delete operatorgroup workload-availability -n "$NS" --ignore-not-found
oc delete catalogsource wao-poc-catalog -n openshift-marketplace --ignore-not-found
echo "WAO removed; CRDs are kept (OLM does not delete them). Delete them only when the cluster is being reset."
```

- [ ] **Step 4: Syntax-check and mark executable**

Run: `chmod +x hack/cluster-*.sh && bash -n hack/cluster-build.sh hack/cluster-install.sh hack/cluster-uninstall.sh && echo ok`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add hack/cluster-build.sh hack/cluster-install.sh hack/cluster-uninstall.sh
git commit -m "hack: disposable-cluster build and install scripts for the FBC catalog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

The cluster run of these scripts happens in Task 15, after the bundle changes, so one cluster cycle covers everything.

---

## Phase 2: Sync tooling and OLM-owned RBAC (sub-issues #13 and #15)

Within one branch these land together: once the runtime overlay stops embedding RBAC, the CSV must carry it in the same build. Commits stay grouped so the work can still be split into two PRs.

### Task 4: `hack/image-commit.sh` and `hack/update-release-set.sh`

**Files:**
- Create: `hack/image-commit.sh`
- Create: `hack/update-release-set.sh`
- Modify: `release-set.yaml`
- Modify: `Makefile` (new `##@ Operands` section replacing the Python one; keep the Python targets until Task 12)

**Interfaces:**
- Produces: `hack/image-commit.sh <image-ref>` prints a 40-hex commit or exits 1. `hack/update-release-set.sh` rewrites `release-set.yaml` in place. New `release-set.yaml` schema per component: `repo`, `version` (label), `tag` (image tag), `commit`, `images.<ENV>.upstream`, `images.<ENV>.pinned`.

Current state of the file (merged on 2026-10-16 as PR #11): every component has `version: v5.8.0`; NHC's images use tag `v5.8.0`, the other five use `latest`; `source` holds the repo URL; `bundle` holds a bundle digest. Verified facts for Step 6: the `v5.8.0` NHC image and the `latest` images of the other five embed exactly each repo's `origin/main` commit as of today: nhc `f130fa28d307003177ec38f27754ac3503a56ecc`, snr `7baef3b210ea5d69dd08c1def063fb5a57eb2c21`, sbr operator and agent `50d20b524e1b16fe895e30f7bd52c868a569b125`, far `f3e85bf5d104ea7d96bf95b701ad3d58e3aea3fc`, mdr `51dd254fd825cfc28e0f55e3c8164b4b3e048bfb`, nmo `dce77e869f202b51a5885078d51baf9b98cd2b66`. No repo has a `v5.8.0` git tag. `skopeo inspect --raw ... | shasum -a 256` reproduces the pinned digests already in the file.

- [ ] **Step 1: Write `hack/image-commit.sh`**

```bash
#!/usr/bin/env bash
# Print the git commit embedded in a medik8s operator image. Every medik8s operator is built by
# hack/build.sh, which passes version.GitCommit=$(git rev-parse HEAD) through -ldflags; the binary
# keeps that string, and `go version -m` prints it without running anything. OCI labels such as
# vcs-ref are inherited from the UBI base image and are NOT used.
# Usage: hack/image-commit.sh quay.io/medik8s/node-healthcheck-operator:v0.12.0
set -euo pipefail
ref=${1:?usage: $0 IMAGE}
command -v skopeo >/dev/null || { echo "skopeo is required" >&2; exit 1; }
command -v go >/dev/null || { echo "go is required" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
skopeo copy --quiet --override-os linux --override-arch amd64 "docker://$ref" "dir:$tmp/img" >/dev/null
mkdir -p "$tmp/root"
for layer in $(jq -r '.layers[].digest' "$tmp/img/manifest.json" | sed 's/^sha256://'); do
  tar -xf "$tmp/img/$layer" -C "$tmp/root" 2>/dev/null || true
done
config=$(jq -r '.config.digest' "$tmp/img/manifest.json" | sed 's/^sha256://')
entry=$(jq -r '(.config.Entrypoint // .config.Cmd // [])[0] // empty' "$tmp/img/$config")
candidates=()
[ -n "$entry" ] && [ -f "$tmp/root/$entry" ] && candidates+=("$tmp/root/$entry")
while IFS= read -r f; do candidates+=("$f"); done < <(find "$tmp/root" -type f -perm -u+x -size +1M 2>/dev/null | head -50)
for bin in "${candidates[@]}"; do
  commit=$(go version -m "$bin" 2>/dev/null | sed -n 's/.*version\.GitCommit=\([0-9a-f]\{40\}\).*/\1/p' | head -1)
  if [ -n "$commit" ]; then echo "$commit"; exit 0; fi
done
echo "no version.GitCommit found in $ref" >&2
exit 1
```

- [ ] **Step 2: Test it against the known value**

Run: `chmod +x hack/image-commit.sh && hack/image-commit.sh quay.io/medik8s/node-healthcheck-operator:v0.12.0`
Expected: `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f` (equals `git -C ~/git/medik8s/node-healthcheck-operator rev-parse v0.12.0`).

Also run it for `quay.io/medik8s/storage-based-remediation-agent:v0.3.0` and `quay.io/medik8s/storage-based-remediation-operator:v0.3.0`.
Expected: both print the same 40-hex commit. If the agent image has no Go binary with the ldflag, record that here and make `update-release-set.sh` treat an agent image without an embedded commit as a warning, not an error, but still require the operator image's commit.

- [ ] **Step 3: Rewrite `release-set.yaml` to the new schema by hand**

For each of the six components keep `version: v5.8.0` and `images`, rename `source` to `repo`, add `tag: v5.8.0` for nhc and `tag: latest` for the other five (the tag part of the current `upstream` references), add `commit: ""`, delete `bundle` and the `# Resolved from ...` comments. Keep `resolvedAt`. Update the header comment:

```yaml
# Upstream medik8s builds of the six components WAO installs. Everything is pinned by digest.
#
# version: display label for this snapshot (a product version such as v5.8.0 or a release tag).
# tag: the image tag the snapshot was resolved from: `latest` (post-submit main build) or a
#   release tag. commit: the git commit the published operator image was built from, read from
#   the binary's embedded version.GitCommit by hack/image-commit.sh. The manifests under
#   config/operands/<k>/upstream are copied from this commit, so they describe the image that runs.
# images: "upstream" is the tag reference written into the embedded runtime manifests; "pinned"
#   is the same image by digest. The operator Deployment carries the pinned digests as
#   RELATED_IMAGE_* and the renderer substitutes them for the upstream references.
#
# Update with `make update-release-set` (latest GitHub release of each repo), or
# `make update-release-set OPERAND_TAG=latest`, `OPERAND_TAG=v0.12.0`, `NHC_TAG=...`.
# `OPERAND_TAG=pinned` keeps every tag and only re-resolves digests and commits.
```

- [ ] **Step 4: Write `hack/update-release-set.sh`**

```bash
#!/usr/bin/env bash
# Rewrite release-set.yaml from published operand images.
# For each component: pick a tag, resolve each image's digest, read the embedded git commit from
# the operator binary (hack/image-commit.sh), and write version, commit, upstream and pinned.
#
# Tag selection (first match wins): <K>_TAG (e.g. NHC_TAG=v0.12.0), OPERAND_TAG, or the latest
# GitHub release. Special values: OPERAND_TAG=pinned keeps the version already in the file;
# OPERAND_TAG=latest selects the post-submit main build.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
for tool in curl skopeo jq go "$YQ"; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }; done

latest_release() { # repo-url -> tag_name
  local api; api=$(sed 's#https://github.com/#https://api.github.com/repos/#' <<<"$1")/releases/latest
  curl -fsSL -H 'Accept: application/vnd.github+json' "$api" | jq -r .tag_name
}
digest_ref() { # tag-ref -> repo@sha256:...
  local repo=${1%:*} d; d=$(skopeo inspect --raw --override-os linux --override-arch amd64 "docker://$1" | shasum -a 256 | cut -d' ' -f1)
  echo "$repo@sha256:$d"
}

for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  K=$(tr '[:lower:]' '[:upper:]' <<<"$k"); override_var="${K}_TAG"
  repo=$("$YQ" ".components.$k.repo" "$RS")
  current=$("$YQ" ".components.$k.tag" "$RS")
  tag=${!override_var:-${OPERAND_TAG:-release}}
  case "$tag" in
    release) tag=$(latest_release "$repo") ;;
    pinned)  tag=$current ;;
  esac
  echo "== $k: $repo @ $tag"
  commit=""
  for env in $("$YQ" ".components.$k.images | keys | .[]" "$RS"); do
    base=$("$YQ" ".components.$k.images.$env.upstream" "$RS"); base=${base%:*}
    upstream="$base:$tag"
    pinned=$(digest_ref "$upstream")
    c=$(hack/image-commit.sh "$upstream" 2>/dev/null || true)
    if [ -z "$c" ]; then echo "   $env: no embedded commit (skipping commit check for this image)"; fi
    if [ -n "$c" ] && [ -n "$commit" ] && [ "$c" != "$commit" ]; then
      echo "   $env: embedded commit $c differs from $commit" >&2; exit 1
    fi
    [ -n "$c" ] && commit=$c
    echo "   $env: $pinned"
    "$YQ" -i ".components.$k.images.$env.upstream = \"$upstream\" | .components.$k.images.$env.pinned = \"$pinned\"" "$RS"
  done
  [ -n "$commit" ] || { echo "   no image of $k embeds version.GitCommit" >&2; exit 1; }
  echo "   commit: $commit"
  # A release tag is also the version label; a `latest` build keeps the label already in the file.
  "$YQ" -i ".components.$k.tag = \"$tag\" | .components.$k.commit = \"$commit\"" "$RS"
  [[ "$tag" =~ ^v[0-9] ]] && "$YQ" -i ".components.$k.version = \"$tag\"" "$RS"
done
"$YQ" -i ".resolvedAt = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$RS"
echo "updated $RS; next: make update-operand-manifests"
```

- [ ] **Step 5: Add Make targets**

Add below `##@ Operands` (above the existing Python block for now):

```make
OPERANDS := nhc snr sbr far mdr nmo
# Checkouts used by update-operand-manifests. Override all with OPERAND_SRC_DIR or one with NHC_PATH etc.
OPERAND_SRC_DIR ?= .cache/operands

.PHONY: update-release-set
update-release-set: yq ## Rewrite release-set.yaml from published images (OPERAND_TAG=release|pinned|latest|<tag>, or NHC_TAG=...).
	YQ=$(YQ) hack/update-release-set.sh
```

- [ ] **Step 6: Run in `pinned` mode and check the result**

Run: `chmod +x hack/update-release-set.sh && make update-release-set OPERAND_TAG=pinned && yq '.components | to_entries[] | .key + " " + .value.tag + " " + .value.commit' release-set.yaml && git diff --stat release-set.yaml`
Expected: six lines each with a 40-hex commit equal to the values listed under Interfaces above; `version` stays `v5.8.0` everywhere; the pinned digests are unchanged (in `git diff release-set.yaml` only `commit`, `tag`, `resolvedAt` and the Step 3 edits change). If a `latest` digest changed, upstream merged since this morning: that is legitimate, record the new digest and the new commit together, and say so in the report.

Then cross-check each commit against the local checkouts (they were fetched today; `origin/main` is the proxy because no repo has a `v5.8.0` tag):
```bash
for p in nhc:node-healthcheck-operator snr:self-node-remediation sbr:storage-based-remediation far:fence-agents-remediation mdr:machine-deletion-remediation nmo:node-maintenance-operator; do k=${p%%:*}; r=${p##*:}; c=$(yq ".components.$k.commit" release-set.yaml); echo "$k $c reachable-from-origin/main=$(git -C ~/git/medik8s/$r merge-base --is-ancestor $c origin/main && echo yes || echo no)"; done
```
Expected: `yes` for every component. A `no` means the local checkout needs `git fetch` or the image was built from a non-main ref; report it.

- [ ] **Step 7: Commit**

```bash
git add hack/image-commit.sh hack/update-release-set.sh release-set.yaml Makefile
git commit -m "operands: discover versions, digests and embedded commits for release-set.yaml

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `hack/update-operand-manifests.sh` copies upstream `config/` at the recorded commit

**Files:**
- Create: `hack/update-operand-manifests.sh`
- Create: `config/operands/<k>/upstream/config/...` (six copies)
- Create: `config/operands/<k>/UPSTREAM.yaml` (six stamps)
- Modify: `Makefile`

**Interfaces:**
- Produces: `config/operands/<k>/upstream/config/{crd,rbac,manager,default,webhook,patches,...}` and `UPSTREAM.yaml` with keys `repo`, `version`, `tag`, `commit`. Then runs `make operand-manifests` (Task 7); until Task 7 exists, run with `SKIP_RENDER=1`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Copy each operand's upstream config/ tree at the commit recorded in release-set.yaml into
# config/operands/<k>/upstream/, following OADP's update-non-admin-manifests. Checkouts live in
# $OPERAND_SRC_DIR/<k> (default .cache/operands/<k>, git-ignored) unless <K>_PATH names one.
# A user-supplied checkout is never modified: objects are read with `git archive <commit>`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
SRC_DIR=${OPERAND_SRC_DIR:-.cache/operands}
# Directories config/default never needs; everything else is kept so kustomize bases resolve.
PRUNE="samples scorecard manifests manifests-k8s manifests-ocp assets"

for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  K=$(tr '[:lower:]' '[:upper:]' <<<"$k"); path_var="${K}_PATH"
  repo=$("$YQ" ".components.$k.repo" "$RS")
  version=$("$YQ" ".components.$k.version" "$RS")
  tag=$("$YQ" ".components.$k.tag" "$RS")
  commit=$("$YQ" ".components.$k.commit" "$RS")
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "$k: release-set.yaml has no commit; run make update-release-set" >&2; exit 1; }
  dir=${!path_var:-$SRC_DIR/$k}
  if [ ! -d "$dir/.git" ]; then
    echo "== $k: cloning $repo into $dir"; mkdir -p "$(dirname "$dir")"; git clone --quiet --no-checkout "$repo" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "== $k: fetching $dir"; git -C "$dir" fetch --quiet --tags origin || true
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || { echo "$k: commit $commit not in $dir" >&2; exit 1; }
  fi
  echo "== $k: copying config/ at $commit ($version) from $dir"
  tmp=$(mktemp -d)
  git -C "$dir" archive "$commit" config | tar -x -C "$tmp"
  for d in $PRUNE; do rm -rf "$tmp/config/$d"; done
  rm -rf "config/operands/$k/upstream"; mkdir -p "config/operands/$k/upstream"
  mv "$tmp/config" "config/operands/$k/upstream/config"; rm -rf "$tmp"
  cat > "config/operands/$k/UPSTREAM.yaml" <<EOF
# Written by hack/update-operand-manifests.sh. Do not edit; run make update-operand-manifests.
repo: $repo
version: $version
tag: $tag
commit: $commit
EOF
done
[ "${SKIP_RENDER:-}" = 1 ] || make operand-manifests
```

- [ ] **Step 2: Add the Make target**

```make
.PHONY: update-operand-manifests
update-operand-manifests: yq ## Copy upstream config/ at the commits in release-set.yaml into config/operands/<k>/upstream, then render.
	YQ=$(YQ) OPERAND_SRC_DIR=$(OPERAND_SRC_DIR) hack/update-operand-manifests.sh

.PHONY: bump-operands
bump-operands: update-release-set update-operand-manifests ## update-release-set then update-operand-manifests, then show the diff.
	git status --short release-set.yaml config/operands config/manager internal/operands
```

- [ ] **Step 3: Run with the local checkouts and verify the copies**

Run:
```bash
chmod +x hack/update-operand-manifests.sh
SKIP_RENDER=1 NHC_PATH=$HOME/git/medik8s/node-healthcheck-operator SNR_PATH=$HOME/git/medik8s/self-node-remediation SBR_PATH=$HOME/git/medik8s/storage-based-remediation FAR_PATH=$HOME/git/medik8s/fence-agents-remediation MDR_PATH=$HOME/git/medik8s/machine-deletion-remediation NMO_PATH=$HOME/git/medik8s/node-maintenance-operator make update-operand-manifests
for k in nhc snr sbr far mdr nmo; do echo "$k: $(find config/operands/$k/upstream -type f | wc -l | tr -d ' ') files; $(ls config/operands/$k/upstream/config | tr '\n' ' ')"; done
cat config/operands/nhc/UPSTREAM.yaml
```
Expected: each operand lists `crd default manager rbac` at least, `webhook` for all but mdr (sbr has `webhook` too although its `default` does not include it; keep it), `patches` for nhc, no `samples`, `scorecard`, `manifests*` or `assets`; NHC stamp shows `commit: f130fa28d307003177ec38f27754ac3503a56ecc` and `tag: v5.8.0`. The local checkouts' HEADs are behind `origin/main` but the objects were fetched today, so `git archive <commit>` works without touching their working trees.

Then prove the clone path works too: `SKIP_RENDER=1 OPERAND_SRC_DIR=$(mktemp -d)/operands make update-operand-manifests` for one component is enough; instead run `SKIP_RENDER=1 MDR_PATH=$(mktemp -d)/mdr make update-operand-manifests` and confirm it clones MDR and produces an identical `config/operands/mdr` (`git status --short config/operands/mdr` shows no new changes after the second run).

- [ ] **Step 4: Verify kustomize can build every upstream default from the copy**

Run: `for k in nhc snr sbr far mdr nmo; do bin/kustomize build config/operands/$k/upstream/config/default >/dev/null 2>/tmp/k.err && echo "$k ok" || { echo "$k FAILED"; head -3 /tmp/k.err; }; done`
Expected: six `ok`. Warnings about deprecated `vars` or `commonLabels` are acceptable; errors are not.

- [ ] **Step 5: Commit**

```bash
git add hack/update-operand-manifests.sh Makefile config/operands
git commit -m "operands: copy upstream config trees at the recorded commits

Six copies under config/operands/<k>/upstream with UPSTREAM.yaml stamps,
produced by hack/update-operand-manifests.sh from local checkouts or a
clone under .cache/operands.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Hand-written `rbac/` and `runtime/` overlays per operand

**Files:**
- Create: `config/operands/<k>/rbac/kustomization.yaml` (six)
- Create: `config/operands/<k>/runtime/kustomization.yaml` (six)
- Create: `config/operands/{nhc,snr,far,nmo}/runtime/webhook_cert_patch.yaml`
- Create: `config/operands/snr/runtime/manager_image_env_patch.yaml`, `config/operands/sbr/runtime/agent_image_env_patch.yaml`

**Interfaces:**
- Produces: `kustomize build config/operands/<k>/rbac` emits only ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding with the upstream name prefix. `kustomize build config/operands/<k>/runtime` emits the upstream default build with namespace `__WAO_NAMESPACE__`, the image set to the `upstream` reference, component labels on pod templates and Service selectors, and service-ca wiring on webhook operands.

Facts about the upstream trees at the recorded commits (from `kustomize build config/default` of each repo's `origin/main` on 2026-10-16, which is what the images embed):

| k | namePrefix | image after upstream `config/manager` images transformer | placeholder env | webhook in default | existing cert volume | Service selectors |
|---|---|---|---|---|---|---|
| nhc | `node-healthcheck-` (from `config/patches/common`) | `controller:latest`, no images transformer | none | yes | none | unique via commonLabels |
| snr | `self-node-remediation-` | `quay.io/medik8s/self-node-remediation-operator:v5.8.0` | `SELF_NODE_REMEDIATION_IMAGE=${IMG}` | yes | none | unique |
| sbr | `sbr-operator-` | `quay.io/medik8s/storage-based-remediation-operator:v5.8.0` | `RELATED_IMAGE_AGENT=${AGENT_IMG}` | no | none | unique |
| far | `fence-agents-remediation-` | `quay.io/medik8s/fence-agents-remediation-operator:v5.8.0` | none | yes | none | unique |
| mdr | `machine-deletion-remediation-` | `quay.io/medik8s/machine-deletion-remediation-operator:v5.8.0` | none | no | none | `control-plane: controller-manager` only (matches every operand) |
| nmo | `node-maintenance-operator-` | `quay.io/medik8s/node-maintenance-operator:v5.8.0` | none | yes | volume `cert`, secret `webhook-server-cert`, mounted at `/tmp/k8s-webhook-server/serving-certs` | unique |

The `images:` entry in each runtime overlay must set the image to the `upstream` value in `release-set.yaml`: nhc `quay.io/medik8s/node-healthcheck-operator:v5.8.0`, and `quay.io/medik8s/<repo>:latest` for the other five (SBR agent env `quay.io/medik8s/storage-based-remediation-agent:latest`). Re-check the table against the copied trees in `config/operands/<k>/upstream/config` before writing; if a fact differs, follow the tree and note it in the report.

Upstream metrics Services live in `config/rbac` for nhc, snr, far, mdr, nmo; SBR's is in `config/default`.

- [ ] **Step 1: Write the six `rbac/kustomization.yaml`**

Template (NHC shown; substitute the prefix per the table):

```yaml
# Operand RBAC for the WAO CSV. operator-sdk folds every Role and ClusterRole bound to a
# ServiceAccount named in --extra-service-accounts (Makefile OPERAND_SERVICE_ACCOUNTS) into the
# CSV; unbound ClusterRoles become standalone bundle objects. OLM creates all of it at install.
# The metrics Service also lives in upstream config/rbac; the runtime overlay renders it instead.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: node-healthcheck-
resources:
- ../upstream/config/rbac
patches:
- target:
    kind: Service
  patch: |
    $patch: delete
    apiVersion: v1
    kind: Service
    metadata:
      name: any
```

For SBR omit the `patches:` block (no Service in its rbac dir). For NHC also check `config/operands/nhc/upstream/config/default/manager_role_patch.yaml`: it only adds a label to `manager-role`, so it is not needed for folding; leave it out.

- [ ] **Step 2: Verify the rbac builds**

Run: `for k in nhc snr sbr far mdr nmo; do echo "== $k"; bin/kustomize build config/operands/$k/rbac 2>/dev/null | yq -N '.kind + " " + .metadata.name' | sort | uniq -c | awk '{print $2}' | sort | uniq -c; done`
Expected per operand: only `ClusterRole`, `ClusterRoleBinding`, `Role`, `RoleBinding`, `ServiceAccount`; no `Service`. ServiceAccount names: `node-healthcheck-controller-manager`, `self-node-remediation-controller-manager`, `sbr-operator-controller-manager` and `sbr-operator-sbr-agent`, `fence-agents-remediation-controller-manager`, `machine-deletion-remediation-controller-manager`, `node-maintenance-operator-controller-manager`. If `$patch: delete` with a `target` selector is rejected by kustomize v5.6, use instead a patch per Service name (`controller-manager-metrics-service`, pre-prefix name) with `$patch: delete`.

- [ ] **Step 3: Write the `runtime/kustomization.yaml` for NHC**

```yaml
# Runtime objects WAO applies when the component is enabled: Deployment, Services, ConfigMaps and
# webhook configurations. `make operand-manifests` builds this, drops every other kind, and writes
# internal/operands/manifests/nhc/objects.yaml. The namespace placeholder and the upstream image
# reference are replaced by the Go renderer at reconcile time.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: __WAO_NAMESPACE__
resources:
- ../upstream/config/default
images:
# newName and newTag are kept equal to release-set.yaml images.*.upstream by `make operand-manifests`.
- name: controller
  newName: quay.io/medik8s/node-healthcheck-operator
  newTag: v5.8.0
labels:
# Every operand pod and every Service selector carries the component label (design brief D10):
# all six managers share one namespace and some upstream selectors would match other managers.
- pairs:
    workloadavailability.medik8s.io/component: nodeHealthCheck
  fields:
  - path: spec/template/metadata/labels
    kind: Deployment
    create: true
  - path: spec/selector
    kind: Service
    create: true
patches:
- path: webhook_cert_patch.yaml
```

`config/operands/nhc/runtime/webhook_cert_patch.yaml` (one file, three documents, strategic merge; kustomize applies each document to the object it names):

```yaml
# OpenShift service-ca wiring, which OLM would do for a standalone install. The Service asks
# service-ca for a serving certificate in Secret node-healthcheck-webhook-server-cert; the
# Deployment mounts it where controller-runtime expects it; the webhook configuration gets the CA.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-healthcheck-controller-manager
spec:
  template:
    spec:
      containers:
      - name: manager
        volumeMounts:
        - name: webhook-server-cert
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
      volumes:
      - name: webhook-server-cert
        secret:
          secretName: node-healthcheck-webhook-server-cert
          defaultMode: 420
---
apiVersion: v1
kind: Service
metadata:
  name: node-healthcheck-webhook-service
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: node-healthcheck-webhook-server-cert
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: node-healthcheck-validating-webhook-configuration
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
```

If kustomize refuses a multi-document patch file, split into `webhook_cert_patch.yaml`, `webhook_service_patch.yaml`, `webhook_config_patch.yaml` and list all three under `patches:`.

- [ ] **Step 4: Write the other five runtime overlays**

Same shape with these differences:

- **snr**: `images: - name: quay.io/medik8s/self-node-remediation-operator` (newName same, newTag `latest`); label pair value `selfNodeRemediation`; patches: `webhook_cert_patch.yaml` (Deployment `self-node-remediation-controller-manager`, Service `self-node-remediation-webhook-service`, secret `self-node-remediation-webhook-server-cert`, plus a fourth document for `MutatingWebhookConfiguration` `self-node-remediation-mutating-webhook-configuration` with the inject-cabundle annotation) and `manager_image_env_patch.yaml`:
  ```yaml
  # Upstream leaves ${IMG} for envsubst; WAO sets the upstream reference, which the renderer
  # replaces with RELATED_IMAGE_SNR_MANAGER. `make operand-manifests` keeps the value current.
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: self-node-remediation-controller-manager
  spec:
    template:
      spec:
        containers:
        - name: manager
          env:
          - name: SELF_NODE_REMEDIATION_IMAGE
            value: quay.io/medik8s/self-node-remediation-operator:latest
  ```
- **sbr**: `images: - name: quay.io/medik8s/storage-based-remediation-operator`, newTag `latest`; label `storageBasedRemediation`; no webhook patch; `agent_image_env_patch.yaml` sets env `RELATED_IMAGE_AGENT` to `quay.io/medik8s/storage-based-remediation-agent:latest` on Deployment `sbr-operator-controller-manager`.
- **far**: `images: - name: quay.io/medik8s/fence-agents-remediation-operator`, newTag `latest`; label `fenceAgentsRemediation`; webhook patch with Deployment `fence-agents-remediation-controller-manager`, Service `fence-agents-remediation-webhook-service`, both Validating and Mutating configurations (`fence-agents-remediation-validating-webhook-configuration`, `fence-agents-remediation-mutating-webhook-configuration`).
- **mdr**: `images: - name: quay.io/medik8s/machine-deletion-remediation-operator`, newTag `latest`; label `machineDeletionRemediation`; no patches.
- **nmo**: `images: - name: quay.io/medik8s/node-maintenance-operator`, newTag `latest`; label `nodeMaintenance`; webhook patch where the Deployment document modifies the EXISTING volume named `cert` (not a new volume) and adds no volumeMount:
  ```yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: node-maintenance-operator-controller-manager
  spec:
    template:
      spec:
        volumes:
        - name: cert
          secret:
            secretName: node-maintenance-operator-webhook-server-cert
            defaultMode: 420
  ```
  plus Service `node-maintenance-operator-webhook-service` and `ValidatingWebhookConfiguration` `node-maintenance-operator-validating-webhook-configuration` documents.

- [ ] **Step 5: Verify every runtime build**

Run:
```bash
for k in nhc snr sbr far mdr nmo; do echo "== $k"; bin/kustomize build config/operands/$k/runtime 2>/dev/null > /tmp/$k.yaml || { echo BUILD FAILED; continue; }
yq -N 'select(.kind=="Deployment") | .metadata.namespace + " img=" + .spec.template.spec.containers[0].image + " vols=" + ((.spec.template.spec.volumes // []) | map(.name + ":" + (.secret.secretName // "-")) | join(",")) + " podlabel=" + .spec.template.metadata.labels["workloadavailability.medik8s.io/component"]' /tmp/$k.yaml
yq -N 'select(.kind=="Service") | .metadata.name + " sel=" + (.spec.selector["workloadavailability.medik8s.io/component"] // "MISSING")' /tmp/$k.yaml
yq -N 'select(.kind=="ValidatingWebhookConfiguration" or .kind=="MutatingWebhookConfiguration") | .kind + " ca=" + (.metadata.annotations["service.beta.openshift.io/inject-cabundle"] // "MISSING") + " ns=" + .webhooks[0].clientConfig.service.namespace' /tmp/$k.yaml
grep -c '\${' /tmp/$k.yaml || true; done
```
Expected: namespace `__WAO_NAMESPACE__` everywhere; image equals the `upstream` tag reference; webhook operands have exactly one cert volume (`webhook-server-cert` for nhc/snr/far, `cert` for nmo) pointing at `<prefix>-webhook-server-cert`; every pod template and every Service selector shows the component label; every webhook configuration has `ca=true` and `ns=__WAO_NAMESPACE__`; the `${` count is 0 for every operand (the env patches replaced `${IMG}` and `${AGENT_IMG}`).

If the `labels[].fields` form is not honoured by kustomize v5.6 (Service selectors show MISSING), fall back to `includeSelectors: false`, `includeTemplates: true` and add an explicit strategic-merge patch on MDR's `machine-deletion-remediation-controller-manager-metrics-service` adding the label to `spec.selector`; then update the renderer test in Task 7 to assert only pod labels plus the MDR selector.

- [ ] **Step 6: Commit**

```bash
git add config/operands/*/rbac config/operands/*/runtime
git commit -m "operands: rbac and runtime kustomize overlays over the upstream copies

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `make operand-manifests` renders runtime objects; Go loader reads one file per component

**Files:**
- Modify: `Makefile` (new target; `operand-manifests` replaces the Python one of the same name, so delete the old `operand-manifests` and `operand-manifests-check` recipes now)
- Create: `config/operands/crd/kustomization.yaml` (generated)
- Modify: `config/crd/kustomization.yaml`
- Delete: `config/crd/bases/<12 operand CRDs>`
- Modify: `internal/operands/embed.go`, `internal/operands/render.go`
- Modify: `internal/operands/render_test.go`, `internal/components/components_test.go`
- Modify: `internal/components/{nhc,snr,sbr,far,mdr,nmo}.go` (`Original` values)
- Delete: `internal/operands/manifests/*/*.yaml`, `internal/operands/manifests/provenance.json`
- Create: `internal/operands/manifests/<k>/objects.yaml` (generated)

**Interfaces:**
- Produces: `operands.Load(dir)` returns `map[string][]byte` keyed `<Kind>/<name>` from `manifests/<dir>/objects.yaml`. `Render` emits only Deployment, Service, ConfigMap, ValidatingWebhookConfiguration, MutatingWebhookConfiguration. `components.Definition.Images[i].Original` equals `release-set.yaml` `images.<Env>.upstream`.

- [ ] **Step 1: Write the failing Go tests first**

In `internal/operands/render_test.go`:
- Delete `TestRenderGrantsCSVNamespacedPermissionsClusterWide` and `olmNamespacesRule`.
- In `TestRenderSNRReplacesAgentImageEnv` delete the `ClusterRoleBinding` block (the last five lines of the test).
- Replace `TestRenderOrdersRBACBeforeWorkloadsAndWebhooksLast` with:

```go
func TestRenderOrdersServicesBeforeDeploymentsAndWebhooksLast(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, o := range objs {
		if _, seen := pos[o.GetKind()]; !seen {
			pos[o.GetKind()] = i
		}
	}
	if pos["Service"] >= pos["Deployment"] ||
		pos["Deployment"] >= pos["ValidatingWebhookConfiguration"] ||
		pos["Deployment"] >= pos["MutatingWebhookConfiguration"] {
		t.Fatalf("unexpected order: %v", pos)
	}
}

// RBAC is created by OLM from the WAO CSV (config/operands/<k>/rbac); the renderer must never emit it.
func TestRenderEmitsNoRBAC(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		if len(objs) == 0 {
			t.Fatalf("%s: nothing rendered", def.Key)
		}
		for _, o := range objs {
			switch o.GetKind() {
			case "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding":
				t.Errorf("%s: rendered %s/%s; RBAC belongs to the CSV", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}

// Design brief D10: all six managers share a namespace, so every pod template and every Service
// selector carries the component label; otherwise MDR's metrics Service would select every manager.
func TestRenderLabelsPodTemplatesAndServiceSelectors(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			switch o.GetKind() {
			case "Deployment":
				labels, _, _ := unstructured.NestedStringMap(o.Object, "spec", "template", "metadata", "labels")
				if labels[operands.LabelComponent] != def.Key {
					t.Errorf("%s: Deployment/%s pod template label = %q", def.Key, o.GetName(), labels[operands.LabelComponent])
				}
			case "Service":
				sel, _, _ := unstructured.NestedStringMap(o.Object, "spec", "selector")
				if sel[operands.LabelComponent] != def.Key {
					t.Errorf("%s: Service/%s selector = %v", def.Key, o.GetName(), sel)
				}
			}
		}
	}
}

// Webhook operands mount exactly one service-ca certificate volume at the controller-runtime path.
func TestRenderWebhookOperandsMountOneCertVolume(t *testing.T) {
	for _, def := range components.All() {
		if len(def.Webhooks) == 0 {
			continue
		}
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		dep := find(t, objs, "Deployment", def.Deployments[0])
		containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
		mounts := 0
		for _, c := range containers {
			vms, _, _ := unstructured.NestedSlice(c.(map[string]interface{}), "volumeMounts")
			for _, vm := range vms {
				if vm.(map[string]interface{})["mountPath"] == "/tmp/k8s-webhook-server/serving-certs" {
					mounts++
				}
			}
		}
		if mounts != 1 {
			t.Errorf("%s: %d mounts at the serving-certs path, want 1", def.Key, mounts)
		}
		vols, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "volumes")
		certVols := 0
		for _, v := range vols {
			secret, _, _ := unstructured.NestedString(v.(map[string]interface{}), "secret", "secretName")
			if strings.HasSuffix(secret, "-webhook-server-cert") {
				certVols++
			}
		}
		if certVols != 1 {
			t.Errorf("%s: %d cert volumes, want 1 (volumes: %v)", def.Key, certVols, vols)
		}
	}
}
```

In `internal/components/components_test.go` add (needs `os`, `path/filepath`, `sigs.k8s.io/yaml` imports):

```go
// Original image references are the `upstream` values in release-set.yaml: the runtime overlays
// set them (make operand-manifests) and the renderer swaps them for the pinned RELATED_IMAGE_*.
func TestOriginalImagesMatchReleaseSet(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "release-set.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var rs struct {
		Components map[string]struct {
			Images map[string]struct{ Upstream string } `json:"images"`
		} `json:"components"`
	}
	if err := yaml.Unmarshal(raw, &rs); err != nil {
		t.Fatal(err)
	}
	for _, d := range components.All() {
		comp, ok := rs.Components[d.ShortName]
		if !ok {
			t.Fatalf("%s: no release-set entry %q", d.Key, d.ShortName)
		}
		for _, img := range d.Images {
			if got := comp.Images[img.Env].Upstream; got != img.Original {
				t.Errorf("%s: Original for %s = %q, release-set.yaml upstream = %q", d.Key, img.Env, img.Original, got)
			}
		}
	}
}
```

Also update `TestEveryDefinitionMatchesItsManifests`: it checks `name: <dep>\n`; keep as is (the multi-document file still contains those lines).

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/operands/... ./internal/components/... 2>&1 | tail -20`
Expected: failures in `TestRenderEmitsNoRBAC` (RBAC still rendered) and `TestRenderLabelsPodTemplatesAndServiceSelectors` (Service selectors lack the label). `TestOriginalImagesMatchReleaseSet` may already pass, because the current `Original` values (`v5.8.0` for NHC, `latest` for the others) equal today's `upstream` values; it still pins the relationship for future bumps.

- [ ] **Step 3: Change the Go loader and renderer**

`internal/operands/embed.go`: replace `Load` with a multi-document reader.

```go
package operands

import (
	"bytes"
	"embed"
	"fmt"
	"path"
	"sort"

	"sigs.k8s.io/yaml"
)

//go:embed manifests
var manifests embed.FS

// Load returns the objects of one component's objects.yaml keyed by "<Kind>/<name>".
// The file is written by `make operand-manifests` from config/operands/<dir>/runtime.
func Load(dir string) (map[string][]byte, error) {
	b, err := manifests.ReadFile(path.Join("manifests", dir, "objects.yaml"))
	if err != nil {
		return nil, fmt.Errorf("manifests for %q: %w", dir, err)
	}
	out := map[string][]byte{}
	for _, doc := range bytes.Split(b, []byte("\n---\n")) {
		doc = bytes.TrimSpace(doc)
		if len(doc) == 0 {
			continue
		}
		var head struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		}
		if err := yaml.Unmarshal(doc, &head); err != nil {
			return nil, fmt.Errorf("manifests for %q: %w", dir, err)
		}
		key := head.Kind + "/" + head.Metadata.Name
		if _, dup := out[key]; dup {
			return nil, fmt.Errorf("manifests for %q: duplicate %s", dir, key)
		}
		out[key] = doc
	}
	return out, nil
}
```

Keep `sortedNames` unchanged.

`internal/operands/render.go`: change the two maps.

```go
var namespacedKinds = map[string]bool{"Deployment": true, "Service": true, "ConfigMap": true}

// Only workload and admission kinds are rendered. Operand RBAC is part of the WAO CSV
// (config/operands/<k>/rbac) and is created by OLM at install time.
var kindOrder = map[string]int{"ConfigMap": 30, "Service": 40, "Deployment": 50,
	"ValidatingWebhookConfiguration": 60, "MutatingWebhookConfiguration": 61}
```

Update the `Render` doc comment to "sorted so that Services precede Deployments and admission configurations come last".

`internal/components/*.go`: `Original` must equal the `upstream` values in `release-set.yaml` (today: nhc `quay.io/medik8s/node-healthcheck-operator:v5.8.0`, the other five `quay.io/medik8s/<repo>:latest`, SBR agent `quay.io/medik8s/storage-based-remediation-agent:latest`); change any that differ. Update the `ImageBinding` comment in `component.go`: "the upstream reference from release-set.yaml that the runtime overlay writes into the embedded manifests".

- [ ] **Step 4: Add the render target and wire the CRDs**

Makefile, in `##@ Operands`, replacing the Python `operand-manifests`/`operand-manifests-check`:

```make
# Kinds the Go renderer applies at enable time. Everything else in the upstream default build
# (Namespace, CRDs, RBAC) is either shipped in the CSV or not WAO's to create.
RUNTIME_KINDS := Deployment Service ConfigMap ValidatingWebhookConfiguration MutatingWebhookConfiguration
RUNTIME_FILTER := select($(foreach k,$(RUNTIME_KINDS),.kind == "$(k)" or) false)

.PHONY: operand-manifests
operand-manifests: kustomize yq ## Render runtime manifests, CRD list and RELATED_IMAGE_* from config/operands and release-set.yaml (offline).
	@set -e; for k in $(OPERANDS); do \
	  for env in $$($(YQ) ".components.$$k.images | keys | .[]" release-set.yaml); do \
	    upstream=$$($(YQ) ".components.$$k.images.$$env.upstream" release-set.yaml); \
	    case $$env in \
	      RELATED_IMAGE_SBR_AGENT) $(YQ) -i "(.spec.template.spec.containers[] | select(.name == \"manager\") | .env[] | select(.name == \"RELATED_IMAGE_AGENT\") | .value) = \"$$upstream\"" config/operands/sbr/runtime/agent_image_env_patch.yaml ;; \
	      *) name=$$($(YQ) '.images[0].name' config/operands/$$k/runtime/kustomization.yaml); \
	         (cd config/operands/$$k/runtime && $(KUSTOMIZE) edit set image $$name=$$upstream) ;; \
	    esac; \
	    if [ $$k = snr ]; then $(YQ) -i "(.spec.template.spec.containers[] | select(.name == \"manager\") | .env[] | select(.name == \"SELF_NODE_REMEDIATION_IMAGE\") | .value) = \"$$upstream\"" config/operands/snr/runtime/manager_image_env_patch.yaml; fi; \
	  done; \
	  mkdir -p internal/operands/manifests/$$k; \
	  $(KUSTOMIZE) build config/operands/$$k/runtime | $(YQ) '$(RUNTIME_FILTER)' > internal/operands/manifests/$$k/objects.yaml; \
	  test -s internal/operands/manifests/$$k/objects.yaml; \
	  if grep -q '\$${' internal/operands/manifests/$$k/objects.yaml; then echo "$$k: unreplaced placeholder"; exit 1; fi; \
	done
	@{ echo '# Generated by make operand-manifests: the operand CRDs shipped in the WAO CSV.'; \
	   echo 'apiVersion: kustomize.config.k8s.io/v1beta1'; echo 'kind: Kustomization'; echo 'resources:'; \
	   for f in $$(ls config/operands/*/upstream/config/crd/bases/*.yaml | sort); do echo "- ../$${f#config/operands/}"; done; } > config/operands/crd/kustomization.yaml
	@for env in $$($(YQ) '[.components[].images | keys | .[]] | .[]' release-set.yaml); do \
	  img=$$($(YQ) ".components[].images.$$env.pinned // \"\"" release-set.yaml | grep . ); \
	  $(YQ) -i "(select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$$env\") | .value) = \"$$img\"" config/manager/manager.yaml; \
	done
```

Notes for the implementer: `kustomize edit set image name=newName:newTag` rewrites the `images` entry, so the hand-written `name:` is read first with yq and passed back. The SNR env value is the SNR manager image (SNR runs its agent from its own image). yq `-i` on a multi-document patch file applies the expression to the document that matches; the `select(.kind==...)` guards above are not needed there because only the Deployment document has `spec.template`. If `yq -i` rewrites comments or quoting in the patch files in a way that churns diffs, that is acceptable once; it is stable afterwards.

`config/crd/kustomization.yaml`: replace the twelve `- bases/<operand>.yaml` lines with one line `- ../operands/crd` and keep `- bases/workloadavailability.medik8s.io_workloadavailabilityconfigs.yaml`. Delete the twelve operand CRD files from `config/crd/bases/` (`git rm config/crd/bases/{fence-agents,machine-deletion,nodemaintenance,remediation,self-node,storage-based}*`).

Delete the old generated tree: `git rm -r internal/operands/manifests` then `mkdir -p internal/operands/manifests`.

- [ ] **Step 5: Render and run the tests**

Run: `make operand-manifests && ls internal/operands/manifests/*/objects.yaml && cat config/operands/crd/kustomization.yaml && git diff --stat config/manager/manager.yaml && go test ./internal/operands/... ./internal/components/... ./internal/images/...`
Expected: six `objects.yaml`; twelve CRD lines; `manager.yaml` unchanged (digests already equal the pinned values); all Go tests pass.

Check the rendered object counts match the old pipeline minus RBAC and plus nothing:
```bash
for k in nhc snr sbr far mdr nmo; do echo -n "$k: "; yq -N '.kind' internal/operands/manifests/$k/objects.yaml | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; echo; done
```
Expected: nhc Deployment=1 Service=2 ValidatingWebhookConfiguration=1; snr ConfigMap=1 Deployment=1 Service=2 Validating=1 Mutating=1; sbr Deployment=1 Service=1; far ConfigMap=1 Deployment=1 Service=2 Validating=1 Mutating=1; mdr ConfigMap=1 Deployment=1 Service=1; nmo Deployment=1 Service=2 Validating=1.

Also confirm `kustomize build config/crd | yq -N '.metadata.name' | wc -l` prints 13.

- [ ] **Step 6: Run `make operand-manifests` twice and confirm idempotence**

Run: `make operand-manifests && git status --short config internal/operands`
Expected: the second run produces no further changes (only the changes from the first run remain staged or unstaged).

- [ ] **Step 7: Commit**

```bash
git add Makefile config/crd config/operands internal/operands internal/components
git commit -m "operands: render runtime manifests from the kustomize overlays

The Go renderer now loads one objects.yaml per component and emits no RBAC.
Original image references equal release-set.yaml upstream values.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Operand RBAC into the CSV, union role removed, controller markers trimmed

**Files:**
- Modify: `config/manifests/kustomization.yaml`
- Modify: `Makefile` (`bundle` recipe, new `OPERAND_SERVICE_ACCOUNTS`)
- Delete: `config/rbac/operand_union_role.yaml`
- Modify: `config/rbac/kustomization.yaml`
- Modify: `internal/controller/workloadavailabilityconfig_controller.go` (markers and comments)
- Modify: `internal/controller/workloadavailabilityconfig_controller_test.go`
- Regenerated: `config/rbac/role.yaml`, `bundle/`

**Interfaces:**
- Produces: `bundle/manifests/workload-availability-operator.clusterserviceversion.yaml` with one `permissions` and one `clusterPermissions` entry per operand ServiceAccount; twenty standalone ClusterRole files in `bundle/manifests`.

- [ ] **Step 1: Update the controller test first**

In `workloadavailabilityconfig_controller_test.go`:
- In "installs the NHC operand when enabled": replace the block from `Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{})).To(Succeed())` through the `ServiceAccount` `Succeed()` line with:
  ```go
  // RBAC is OLM's: the CSV carries it (config/operands/nhc/rbac). WAO must not create any.
  Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{}))).To(BeTrue())
  Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &rbacv1.Role{}))).To(BeTrue())
  Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &corev1.ServiceAccount{}))).To(BeTrue())
  ```
- In the disable test, delete the three `IsNotFound ... ClusterRole/ClusterRoleBinding` expectations for `node-healthcheck-controller-manager` and `-all-namespaces` (they are now trivially true and misleading).
- In "runs the disable sequence and drops its finalizer on deletion", delete the `sbr-operator-sbr-agent-role` ClusterRole expectation.
- Keep the `rbacv1` import only if still used; otherwise remove it.

- [ ] **Step 2: Run the controller tests to see the NHC test fail**

Run: `make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -20`
Expected: FAIL in "installs the NHC operand when enabled" is NOT expected anymore because Task 7 already stopped rendering RBAC; the test should pass. If it fails, the renderer still emits RBAC; fix Task 7 first.

- [ ] **Step 3: Wire the operand RBAC into the bundle**

`config/manifests/kustomization.yaml` resources:
```yaml
resources:
- bases/workload-availability-operator.clusterserviceversion.yaml
- ../default
- ../samples
- ../scorecard
# Operand RBAC, copied from each upstream checkout (config/operands/<k>/upstream) and wrapped with
# the upstream name prefix. operator-sdk folds it into the CSV for the ServiceAccounts listed in
# OPERAND_SERVICE_ACCOUNTS (Makefile); OLM creates it at install. Same pattern as OADP's
# config/non-admin-controller_rbac.
- ../operands/nhc/rbac
- ../operands/snr/rbac
- ../operands/sbr/rbac
- ../operands/far/rbac
- ../operands/mdr/rbac
- ../operands/nmo/rbac
```

Makefile: near `BUNDLE_METADATA_OPTS` add
```make
# Operand ServiceAccounts whose Roles and ClusterRoles operator-sdk folds into the CSV. A name
# missing here silently becomes dozens of standalone bundle files; verify-operand-manifests checks it.
OPERAND_SERVICE_ACCOUNTS := node-healthcheck-controller-manager,self-node-remediation-controller-manager,sbr-operator-controller-manager,sbr-operator-sbr-agent,fence-agents-remediation-controller-manager,machine-deletion-remediation-controller-manager,node-maintenance-operator-controller-manager
```
(Amended in the final-review fix: `sbr-operator-sbr-agent` moved out of this list into
`OPERAND_STANDALONE_SERVICE_ACCOUNTS`, leaving six folded ServiceAccounts plus the SBR agent's
standalone RBAC, because the SBR manager binds `sbr-operator-sbr-agent-role` by name at runtime; the
bundle build also gained `--load-restrictor LoadRestrictionsNone` for the SBR SCC role.)
and change the generate line in `bundle` to
```make
	$(KUSTOMIZE) build $(MANIFESTS_DIR) | $(OPERATOR_SDK) generate bundle -q --overwrite --version $(VERSION) --extra-service-accounts $(OPERAND_SERVICE_ACCOUNTS) $(BUNDLE_METADATA_OPTS)
```

- [ ] **Step 4: Remove the union role and the controller's RBAC markers**

`git rm config/rbac/operand_union_role.yaml`; in `config/rbac/kustomization.yaml` delete the two lines `# Union of every rule...` and `- operand_union_role.yaml`, and rewrite the admin/editor/viewer comment to: "Those roles are not used by the operator itself and are left out of the POC bundle."

In the controller, replace the marker comment and the RBAC marker:
```go
// RBAC for WAO's own objects. Operand RBAC is not created here: it is part of the WAO CSV
// (config/operands/<k>/rbac) and OLM creates it at install time, as OLM does for OADP's
// non-admin controller.
```
and change the `rbac.authorization.k8s.io` marker line to be removed entirely, and the core marker to `resources=services;configmaps` (no `serviceaccounts`). Keep deployments, daemonsets, events, webhook configurations and the medik8s read markers.

- [ ] **Step 5: Regenerate and inspect**

Run:
```bash
make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper manifests bundle
CSV=bundle/manifests/workload-availability-operator.clusterserviceversion.yaml
yq '.spec.install.spec.permissions[] | .serviceAccountName + " " + (.rules | length | tostring)' $CSV
yq '.spec.install.spec.clusterPermissions[] | .serviceAccountName + " " + (.rules | length | tostring)' $CSV
ls bundle/manifests | grep -v -E 'clusterserviceversion|\.medik8s\.io_' 
grep -c "bind" config/rbac/role.yaml || true
```
Expected: `permissions` lists the WAO SA plus seven operand SAs; `clusterPermissions` lists the WAO SA plus operand SAs with rule counts close to FAR 10/4, MDR 8/3, NHC 17/3, NMO 14/3, SBR 17/3, SBR agent 8, SNR 14/2 (permissions/clusterPermissions; small drift from the prototype is acceptable if it matches the copied upstream files). Standalone files: twenty `*_rbac.authorization.k8s.io_v1_clusterrole.yaml` (six `metrics-reader`, four `ext-remediation`, nine SBR admin/editor/viewer, plus any other unbound role) and nothing of kind Role, RoleBinding or ServiceAccount. `role.yaml` has no `bind`.

Then `make bundle-validate` must pass.

- [ ] **Step 6: Full test run and commit**

Run: `make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -8`
Expected: pass, including `verify-no-changes` (if `bundle-reset` shows a diff in `createdAt` only, that is the existing behaviour and the target handles it).

```bash
git add -A config/manifests config/rbac Makefile internal/controller bundle
git commit -m "rbac: ship operand RBAC in the WAO CSV and stop creating it at runtime

operator-sdk folds Roles bound to the seven operand ServiceAccounts via
--extra-service-accounts; unbound ClusterRoles ship as standalone bundle
objects. The union role and WAO's bind verb are gone.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `hack/verify-operand-manifests.sh` and the Make target

**Files:**
- Create: `hack/verify-operand-manifests.sh`
- Modify: `Makefile`

**Interfaces:**
- Produces: `make verify-operand-manifests` exits non-zero with a named reason on any drift. Offline.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Offline checks that the committed operand files, release-set.yaml, the manager Deployment and the
# bundle agree. CI runs this; it needs no network and no cluster.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
RS=release-set.yaml
fail=0; problem() { echo "verify-operand-manifests: $*" >&2; fail=1; }

# 1. Stamps match release-set.yaml.
for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  stamp=config/operands/$k/UPSTREAM.yaml
  [ -f "$stamp" ] || { problem "$stamp missing"; continue; }
  for f in repo version tag commit; do
    want=$("$YQ" ".components.$k.$f" "$RS"); got=$("$YQ" ".$f" "$stamp")
    [ "$want" = "$got" ] || problem "$k: $f is $got in $stamp but $want in $RS; run make update-operand-manifests"
  done
done

# 2. Rendering the committed overlays reproduces the committed outputs.
make -s operand-manifests
if ! git diff --quiet -- internal/operands/manifests config/operands config/manager/manager.yaml; then
  git --no-pager diff --stat -- internal/operands/manifests config/operands config/manager/manager.yaml >&2
  problem "rendered outputs differ from the committed ones; run make operand-manifests and commit"
fi

# 3. RELATED_IMAGE_* equal the pinned digests.
for env in $("$YQ" '[.components[].images | keys | .[]] | .[]' "$RS"); do
  want=$("$YQ" ".components[].images.$env.pinned // \"\"" "$RS" | grep .)
  got=$("$YQ" "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$env\") | .value" config/manager/manager.yaml)
  [ "$want" = "$got" ] || problem "manager.yaml $env=$got, release-set.yaml pins $want"
done

# 4. Every operand ServiceAccount is in OPERAND_SERVICE_ACCOUNTS.
extra=$(sed -n 's/^OPERAND_SERVICE_ACCOUNTS := //p' Makefile | tr ',' '\n')
for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  for sa in $(bin/kustomize build "config/operands/$k/rbac" 2>/dev/null | "$YQ" -N 'select(.kind == "ServiceAccount") | .metadata.name'); do
    grep -qx "$sa" <<<"$extra" || problem "$k: ServiceAccount $sa is not in OPERAND_SERVICE_ACCOUNTS; its roles would become standalone bundle files"
  done
done

# 5. The bundle carries no standalone Role, RoleBinding or ServiceAccount, and only known ClusterRoles.
for f in bundle/manifests/*.yaml; do
  kind=$("$YQ" '.kind' "$f")
  case "$kind" in
    ClusterServiceVersion|CustomResourceDefinition) ;;
    ClusterRole) name=$("$YQ" '.metadata.name' "$f")
      case "$name" in *-metrics-reader|*-ext-remediation|*-admin-role|*-editor-role|*-viewer-role) ;; *) problem "unexpected standalone ClusterRole $name in $f" ;; esac ;;
    *) problem "unexpected standalone $kind in $f" ;;
  esac
done
crds=$(ls bundle/manifests/*.yaml | xargs -n1 "$YQ" '.kind' | grep -c CustomResourceDefinition || true)
[ "$crds" = 13 ] || problem "bundle has $crds CRDs, want 13"

[ $fail = 0 ] && echo "verify-operand-manifests: OK"
exit $fail
```

- [ ] **Step 2: Make target**

```make
.PHONY: verify-operand-manifests
verify-operand-manifests: kustomize yq ## Offline check that config/operands, release-set.yaml, manager.yaml and the bundle agree (CI).
	YQ=$(YQ) hack/verify-operand-manifests.sh
```

- [ ] **Step 3: Test pass and each failure mode**

Run: `chmod +x hack/verify-operand-manifests.sh && make verify-operand-manifests`
Expected: `verify-operand-manifests: OK`.

Then break each check and confirm the message, restoring with `git checkout` afterwards:
1. `yq -i '.commit = "0000000000000000000000000000000000000000"' config/operands/mdr/UPSTREAM.yaml && make verify-operand-manifests; git checkout config/operands/mdr/UPSTREAM.yaml` → names `mdr: commit`.
2. `sed -i.bak 's/,sbr-operator-sbr-agent//' Makefile && make verify-operand-manifests; mv Makefile.bak Makefile` → names `sbr-operator-sbr-agent`.
3. `yq -i '(select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="RELATED_IMAGE_NHC_MANAGER") | .value) = "quay.io/x@sha256:0000000000000000000000000000000000000000000000000000000000000000"' config/manager/manager.yaml && make verify-operand-manifests; git checkout config/manager/manager.yaml` → names `RELATED_IMAGE_NHC_MANAGER` (note: check 2 re-renders manager.yaml from release-set first, so this one may be reported as drift by check 2 instead; either message is acceptable, the point is a non-zero exit).

- [ ] **Step 4: Commit**

```bash
git add hack/verify-operand-manifests.sh Makefile
git commit -m "operands: offline verification of copies, pins, SA coverage and bundle shape

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: envtest proves enable and disable work without any RBAC rendering

**Files:**
- Modify: `internal/controller/workloadavailabilityconfig_controller_test.go`

- [ ] **Step 1: Add a test that enabling every component creates no RBAC and disabling leaves nothing behind**

Add inside the existing `Describe`:

```go
	It("creates no RBAC for any component and removes every runtime object on disable", func() {
		for _, key := range v1alpha1.AllComponentKeys {
			setState(ctx, key, v1alpha1.ComponentStateEnabled)
		}
		Eventually(func(g Gomega) {
			for _, key := range v1alpha1.AllComponentKeys {
				c := component(getWAC(ctx), key)
				g.Expect(c).NotTo(BeNil())
				g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseProgressing))
			}
		}).Should(Succeed())
		for _, def := range components.All() {
			for _, name := range def.Deployments {
				Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &appsv1.Deployment{})).To(Succeed())
				Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &corev1.ServiceAccount{}))).To(BeTrue(), name)
				Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &rbacv1.ClusterRole{}))).To(BeTrue(), name)
			}
		}
		for _, key := range v1alpha1.AllComponentKeys {
			setState(ctx, key, v1alpha1.ComponentStateDisabled)
		}
		Eventually(func(g Gomega) {
			for _, def := range components.All() {
				for _, name := range def.Deployments {
					g.Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &appsv1.Deployment{}))).To(BeTrue())
				}
			}
		}).Should(Succeed())
	})
```

Place it before the "reports DisableIncomplete" test so ordering-sensitive tests keep their assumptions. If the suite's existing tests assume a specific starting state after this one, reset with `setState(..., Disabled)` as the test already does at its end.

- [ ] **Step 2: Run**

Run: `make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -8`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add internal/controller/workloadavailabilityconfig_controller_test.go
git commit -m "test: enable and disable every component without RBAC rendering

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Phase 3: Remove the Python pipeline (sub-issue #16) and update docs and CI

### Task 11: Delete the Python pipeline, venv plumbing and ConfigMap catalog

**Files:**
- Delete: `hack/fetch-bundles.py`, `hack/extract-operand-manifests.py`, `hack/extract_operand_manifests_test.py`, `hack/check-bundle.py`, `hack/configmap-catalog.py`, `hack/configmap_catalog_test.py`, `hack/requirements.txt`
- Modify: `Makefile` (`PYTHON`, `BUNDLE_CACHE`, `python-env`, `.venv` rules, `bundles`, `bundle-check`, `catalog-configmap`, `test-offline`)
- Modify: `.gitignore` (drop `__pycache__/`, keep `.cache/`)

`hack/build_test.py`, `hack/e2e_runner_test.py` and `test/e2e/run.py` are not part of the manifest pipeline and stay; `test-offline` keeps running the two remaining test files with the system `python3`.

- [ ] **Step 1: Delete files and targets**

```bash
git rm hack/fetch-bundles.py hack/extract-operand-manifests.py hack/extract_operand_manifests_test.py hack/check-bundle.py hack/configmap-catalog.py hack/configmap_catalog_test.py hack/requirements.txt
```

In the Makefile remove `PYTHON ?=`, `BUNDLE_CACHE ?=`, the whole `python-env` block including the `.venv` rules, the order-only line `bundles operand-manifests ... : | python-env`, the `bundles`, `bundle-check` and `catalog-configmap` targets and `CATALOG_NS`. Replace `test-offline` with:

```make
.PHONY: test-offline
test-offline: verify-operand-manifests ## Offline checks: operand manifests, bundle shape, and the remaining script tests (no cluster, no network).
	python3 -m unittest hack/e2e_runner_test.py hack/build_test.py
```

Also remove `__pycache__/` from `.gitignore` only if no Python remains that writes it; since `test/e2e/run.py` remains, keep the line.

- [ ] **Step 2: Verify nothing references the deleted files**

Run: `git grep -n -E 'fetch-bundles|extract-operand-manifests|check-bundle\.py|configmap-catalog|catalog-configmap|python-env|requirements\.txt|wao-poc-catalog\.yaml|\.venv' -- ':!docs/archive' ':!docs/operand-manifests-oadp-approach*' ':!HANDOFF.md' ':!docs/superpowers'`
Expected: only README lines (fixed in Task 13) and possibly `test/olmv1` or `OLM_V1_READINESS.md` historical mentions. Anything in `Makefile`, `.github` or `hack/` is a miss.

- [ ] **Step 3: Run the offline tests**

Run: `make test-offline && make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -5`
Expected: both pass.

- [ ] **Step 4: Commit**

```bash
git add -A Makefile .gitignore hack
git commit -m "build: remove the Python manifest pipeline and ConfigMap catalog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: CI workflow runs the offline verification

**Files:**
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Edit**

Remove the `Setup Python` and `Install Python dependencies` steps. Replace the "Check pinned manifests and run offline tests" step with:

```yaml
      - name: Verify operand manifests and run offline tests
        run: make verify-operand-manifests test-offline
```

`test-offline` still needs `python3` for the two remaining script tests; ubuntu-latest has it.

- [ ] **Step 2: Lint the workflow locally**

Run: `yq '.jobs.test.steps[].name' .github/workflows/test.yml`
Expected: Clone, Setup Go, Verify operand manifests and run offline tests, Running Tests.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: verify operand manifests offline instead of fetching bundles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: README, design brief and HANDOFF updates

**Files:**
- Modify: `README.md` ("Operator image and POC catalog", "Run the POC on a cluster", "Install by hand", the `make operand-manifests` paragraph, "Deviations from the plan")
- Modify: `docs/archive/bootstrap/design-brief.md` (D6, D7, D9 rows: add a trailing "Superseded 2026-10 by #12" note, keep history)
- Modify: `HANDOFF.md` (state: implemented on branch; what was verified)

- [ ] **Step 1: README**

Replace the paragraph beginning "`make operand-manifests` regenerates the operand manifests" with:

```markdown
Operand manifests are copied from each upstream checkout, following OADP's non-admin-controller
pattern. `make update-release-set` records the latest release tag, image digests and the git
commit embedded in each published image into `release-set.yaml`; `make update-operand-manifests`
copies `config/` from a checkout at that commit into `config/operands/<k>/upstream/` (checkouts
live in `.cache/operands`, or set `NHC_PATH` and friends), renders the runtime manifests the Go
renderer embeds, and syncs `RELATED_IMAGE_*`. `make bump-operands` does both. Review the diff and
commit; CI runs `make verify-operand-manifests`, which is offline. Operand RBAC ships in the WAO
CSV via `--extra-service-accounts` and OLM creates it at install; WAO creates no RBAC itself.
```

Replace "Operator image and POC catalog" and "Run the POC on a cluster" and "Install by hand" with one section:

```markdown
## Build, catalog and install on a disposable cluster

The operator, bundle and a file-based catalog (FBC) image are built on the cluster with binary
Docker builds in namespace `wao-poc-build`, from a clean `git archive HEAD`. The bundle references
the operator image by digest and the catalog references the bundle by digest. No external registry
is needed. The kubeconfig is always passed explicitly.

```sh
KC=/path/to/disposable-cluster.kubeconfig
hack/cluster-build.sh "$KC"      # builds three images, writes dist/catalogsource.yaml
hack/cluster-install.sh "$KC"    # CatalogSource, namespace, OperatorGroup, Subscription; waits for the CSV
hack/cluster-uninstall.sh "$KC"  # removes them; CRDs stay
```

`config/catalog/` holds the committed CatalogSource (`sourceType: grpc`) and Subscription
templates. `make catalog-fbc BUNDLE_IMG=<ref>` renders `./bundle` into `catalog/` with `opm` and
`make catalog-build` builds the image locally when a container tool is available. The shared
`make dev-olm-deploy` from medik8s/tools (`TOOLS_DIR=<path to medik8s/tools>`) installs the bundle
with `operator-sdk run bundle` and needs no catalog image.
```

Append to "Deviations from the plan":

```markdown
9. 2026-10: the Python pipeline, the union role and the ConfigMap catalog were replaced by the
   OADP-style approach (GitHub #12 to #16): operand `config/` trees are copied from upstream
   checkouts at the commit embedded in the published image, operand RBAC ships in the WAO CSV and
   OLM creates it, and the dev catalog is an FBC image. Items 2, 3 and 8 are historical; OLM now
   does the cluster-wide promotion of CSV `permissions` for the `AllNamespaces` OperatorGroup.
   Trade-off accepted: operand ServiceAccounts and roles exist from install onward, even while
   every component is Disabled.
```

Also update the "Live install verification" table row only if it references `full-run.sh`; otherwise leave history alone.

- [ ] **Step 2: Design brief and HANDOFF**

Append to the D6, D7 and D9 rows' last column: "Superseded 2026-10 (GitHub #12): FBC catalog / CSV-owned RBAC / OLM rewrites subjects".

Rewrite HANDOFF.md "Where things stand" to say the four sub-issues are implemented on this branch with the commit list, and move "Suggested next steps" to: cluster verification results (Task 15), split into PRs in merge order if desired, open follow-ups.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/archive/bootstrap/design-brief.md HANDOFF.md
git commit -m "docs: describe the OADP-style operand flow and FBC install

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Phase 4: Cluster verification

### Task 14: Reset the disposable cluster (run by the lead, not a subagent)

The cluster currently runs WAO installed through OLM v1 (`ClusterExtension workload-availability-operator`, `ClusterCatalog wao-poc`) with all six components Enabled, an SNR agent DaemonSet, one `SelfNodeRemediationConfig`, two `NodeHealthCheck` objects (`compact-cluster-baseline`, `exp0005-nhc`) and MDR in CrashLoopBackOff. The classic OLM install needs a clean slate. Authorization: the user confirmed this cluster for this session and allowed deleting CRDs and the prior WAO operator.

- [ ] **Step 1: Disable every component so WAO removes its operands, then delete the config**

```bash
KC=/Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig
oc --kubeconfig=$KC whoami --show-server   # must print api.jmatthews-422-rhwa.*
oc --kubeconfig=$KC patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Disabled"},"selfNodeRemediation":{"state":"Disabled"},"storageBasedRemediation":{"state":"Disabled"},"fenceAgentsRemediation":{"state":"Disabled"},"machineDeletionRemediation":{"state":"Disabled"},"nodeMaintenance":{"state":"Disabled"}}}}'
sleep 30; oc --kubeconfig=$KC get deploy -n openshift-workload-availability
```
Expected: only `workload-availability-operator-controller-manager` remains.

- [ ] **Step 2: Remove SNR agents, policies and the config**

```bash
oc --kubeconfig=$KC delete selfnoderemediationconfig --all -n openshift-workload-availability --timeout=120s
oc --kubeconfig=$KC delete nodehealthcheck --all --timeout=60s
oc --kubeconfig=$KC delete workloadavailabilityconfig cluster --timeout=120s
oc --kubeconfig=$KC get ds -n openshift-workload-availability
```
Expected: no DaemonSet. If the WAC deletion hangs on its finalizer, patch the finalizer away only after confirming no operand Deployment remains.

- [ ] **Step 3: Remove the OLM v1 install and leftovers**

```bash
oc --kubeconfig=$KC delete clusterextension workload-availability-operator --timeout=300s
oc --kubeconfig=$KC delete clustercatalog wao-poc
oc --kubeconfig=$KC get crd -o name | grep medik8s     # expect none; if present, delete them
oc --kubeconfig=$KC get clusterrole,clusterrolebinding -o name | grep -E 'node-healthcheck|self-node|sbr-operator|fence-agents|machine-deletion|node-maintenance|workload-availability' 
oc --kubeconfig=$KC get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name | grep -E 'remediation|healthcheck|maintenance'
```
Delete anything the last two commands list that carries the label `app.kubernetes.io/managed-by=workload-availability-operator` or `olm.owner`; report anything else rather than deleting it. Leave `openshift-workload-availability` in place (Subscription template recreates it idempotently) and leave `wao-poc-build`.

- [ ] **Step 4: Record the reset**

Write `evidence/<UTC date>-oadp-reset/RESET.md` (git-ignored) with the commands run and the final `oc get` outputs, no Secret values.

---

### Task 15: Build, install and exercise on the cluster

- [ ] **Step 1: Build the three images on the cluster**

Run: `hack/cluster-build.sh /Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig 2>&1 | tee evidence/$(date -u +%F)-oadp-cluster/build.log`
Expected: three `*_IMG=` lines with digests; `dist/catalogsource.yaml` written. The bundle CSV and `config/manager/kustomization.yaml` are modified by `make bundle IMG=...`; do not commit those (run `git checkout bundle config/manager/kustomization.yaml` at the end, or keep as a reviewed commit only if the user wants the on-cluster digest recorded).

- [ ] **Step 2: Install**

Run: `hack/cluster-install.sh /Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig`
Expected: `installed workload-availability-operator.v0.1.0`, components all `Disabled`.

- [ ] **Step 3: Verify OLM created the operand RBAC while every component is Disabled**

```bash
KC=/Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig; NS=openshift-workload-availability
oc --kubeconfig=$KC get sa -n $NS -o name | sort
oc --kubeconfig=$KC get clusterrole -l olm.owner=workload-availability-operator.v0.1.0 -o name | wc -l
oc --kubeconfig=$KC get clusterrole -o name | grep -E 'metrics-reader|ext-remediation|storagebasedremediation.*-(admin|editor|viewer)-role' | wc -l
oc --kubeconfig=$KC get deploy -n $NS -o name
oc --kubeconfig=$KC get clusterrole,role,rolebinding,clusterrolebinding -A -l app.kubernetes.io/managed-by=workload-availability-operator -o name | wc -l
```
Expected: six folded operand ServiceAccounts plus the SBR agent's standalone ServiceAccount `sbr-operator-sbr-agent`, plus the WAO SA; OLM-owned ClusterRoles present; nineteen ClusterRoles matched by the grep, and `sbr-operator-sbr-agent-role` and `sbr-operator-sbr-agent-privileged-scc` present (twenty-one standalone ClusterRoles in all); only the WAO Deployment; zero WAO-managed RBAC objects. (Amended in the final-review fix: the SBR agent's RBAC ships standalone because the SBR manager binds those two ClusterRoles by name at runtime.)

- [ ] **Step 4: Enable NHC and NMO, then all six, and watch readiness**

```bash
oc --kubeconfig=$KC patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"},"nodeMaintenance":{"state":"Enabled"}}}}'
for i in $(seq 1 24); do oc --kubeconfig=$KC get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name}={.phase} {end}{"\n"}'; sleep 10; done
oc --kubeconfig=$KC logs -n $NS deploy/node-maintenance-operator-controller-manager --tail=30 | grep -i -E 'forbidden|namespaces|Git Commit' || true
```
Expected: `nodeHealthCheck=Available nodeMaintenance=Available`; NMO logs show no `forbidden` on namespaces (deviation 8 regression) and a `Git Commit:` line equal to the `commit` in `release-set.yaml` for nmo.

Then enable the remaining four with the same patch shape (`selfNodeRemediation`, `storageBasedRemediation`, `fenceAgentsRemediation`, `machineDeletionRemediation`). Expected: all `Available` except possibly MDR, which upstream cannot start under its 30Mi limit on this cluster (known upstream issue, README). Record the exact phases.

Admission check without creating real objects (server-side dry run only):
```bash
cat <<'EOF' | oc --kubeconfig=$KC apply --dry-run=server -f -
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: dry-run-only
spec:
  nodeName: does-not-exist
  reason: dry run
EOF
```
Expected: the NMO validating webhook rejects it with a message about the node not existing, proving the webhook is served with a valid service-ca certificate.

- [ ] **Step 5: Disable all, confirm RBAC stays and workloads go**

```bash
oc --kubeconfig=$KC patch workloadavailabilityconfig cluster --type merge -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Disabled"},"selfNodeRemediation":{"state":"Disabled"},"storageBasedRemediation":{"state":"Disabled"},"fenceAgentsRemediation":{"state":"Disabled"},"machineDeletionRemediation":{"state":"Disabled"},"nodeMaintenance":{"state":"Disabled"}}}}'
sleep 45; oc --kubeconfig=$KC get deploy,ds -n $NS; oc --kubeconfig=$KC get sa -n $NS -o name | wc -l
```
Expected: only the WAO Deployment; SNR may leave its DaemonSet if a `SelfNodeRemediationConfig` was created by the operator (SNR creates a default config); if so, `status.components[selfNodeRemediation].phase` is `DisableIncomplete` with the retained resources listed, which is the documented behaviour. ServiceAccount count unchanged (RBAC stays with the CSV).

- [ ] **Step 6: Uninstall and record**

Run: `hack/cluster-uninstall.sh /Users/jmatthews/.kube/clusters/jmatthews-422-rhwa.kubeconfig`
Write `evidence/<UTC date>-oadp-cluster/RESULTS.md` with every command and sanitized output (no Secret values, cluster identifiers are fine inside git-ignored `evidence/`). Then restore the tracked files the build changed: `git checkout bundle config/manager/kustomization.yaml` unless the user asks to record the on-cluster digest.

- [ ] **Step 7: Final full test run**

Run: `make verify-operand-manifests test-offline && make CONTROLLER_GEN=$PWD/bin/controller-gen-wrapper SORT_IMPORTS=$PWD/bin/sort-imports-wrapper test-no-verify-changes 2>&1 | tail -5 && git status --short`
Expected: all pass; tree clean apart from untracked pre-existing files. Remove `evidence/go.mod` at the very end per KI-6.

---

## Self-review notes

- Spec coverage: #13 is Tasks 4, 5, 6, 7, 9; #14 is Tasks 1, 2, 3; #15 is Tasks 7, 8, 10; #16 is Tasks 11, 12; docs are Task 13; cluster acceptance is Tasks 14, 15. The spec's `config/operands/<k>/crd/` directory is realised as `config/operands/crd/kustomization.yaml` pointing into the upstream copies, which avoids a second copy of each CRD; the issue text should be read with that substitution.
- Type consistency: `operands.Load` keeps its `map[string][]byte` signature; `Definition.Images[].Original` keeps its name; `OPERAND_SERVICE_ACCOUNTS` is the single Make variable read by both the `bundle` recipe and the verify script.
- The `labels[].fields` kustomize form and the `$patch: delete` with `target` are the two kustomize behaviours not yet proven in this repo; Task 6 names the fallback for each.
