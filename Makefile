# SHELL defines bash so all the inline scripts here will work as expected.
SHELL := /bin/bash
OPERATOR_NAME := workload-availability-operator

# PLATFORM is the single platform docker-build targets.
# Defaulting to linux/amd64 so that builds on Mac default to building OK for remote clusters
PLATFORM ?= linux/amd64

## Tool versions
# OPERATOR_SDK versions at https://github.com/operator-framework/operator-sdk/releases
# heads up: 1.37 is the last version which supports go/v3!
OPERATOR_SDK_VERSION ?= v1.42.2

# OPM versions at https://github.com/operator-framework/operator-registry/releases
OPM_VERSION = v1.66.0

# CONTROLLER_GEN versions at https://github.com/kubernetes-sigs/controller-tools/releases
CONTROLLER_GEN_VERSION = v0.20.1

# KUSTOMIZE versions at https://github.com/kubernetes-sigs/kustomize/releases
# note: update KUSTOMIZE_VERSION and KUSTOMIZE_API_VERSION accordingly.
KUSTOMIZE_API_VERSION = v5
KUSTOMIZE_VERSION = v5.8.1

# https://pkg.go.dev/sigs.k8s.io/controller-runtime/tools/setup-envtest/env?tab=versions
ENVTEST_VERSION = v0.0.0-20260120065648-aebc15d7c689

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.34

# GoImports versions at https://pkg.go.dev/golang.org/x/tools/cmd/goimports?tab=versions
GOIMPORTS_VERSION ?= v0.44.0

# Sort-imports versions at https://github.com/slintes/sort-imports/releases
SORT_IMPORTS_VERSION = v0.3.0

# update for major version updates to YQ_VERSION! see https://github.com/mikefarah/yq
YQ_API_VERSION = v4
YQ_VERSION = v4.53.2

BLUE_ICON_PATH = ./config/assets/medik8s_blue_icon.png

# VERSION defines the project version for the bundle. 
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=5.8.1)
# - use environment variables to overwrite this value (e.g export VERSION=5.8.1)
DEFAULT_VERSION := 0.1.0
DEFAULT_PREVIOUS_VERSION :=
DEFAULT_SKIP_RANGE_LOWER :=
VERSION ?= $(DEFAULT_VERSION)
PREVIOUS_VERSION ?= $(DEFAULT_PREVIOUS_VERSION)
SKIP_RANGE_LOWER ?= $(DEFAULT_SKIP_RANGE_LOWER)
export VERSION

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "preview,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=preview,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="preview,fast,stable")
CHANNELS ?= stable
export CHANNELS

ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
DEFAULT_CHANNEL ?= stable
export DEFAULT_CHANNEL

# Validate DEFAULT_CHANNEL is in CHANNELS
# When CHANNELS contains comma-separated values (e.g., "stable,beta"), we need to convert
# commas to spaces for filter to match. We use a variable for the comma because Make treats
# commas as function argument delimiters, causing $(subst ,, ,$(CHANNELS)) to misparse.
comma := ,
ifneq (,$(DEFAULT_CHANNEL))
  ifeq (,$(filter $(DEFAULT_CHANNEL),$(subst $(comma), ,$(CHANNELS))))
    $(error DEFAULT_CHANNEL "$(DEFAULT_CHANNEL)" must be present in CHANNELS "$(CHANNELS)")
  endif
endif

ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)
MANIFESTS_DIR ?= config/manifests

# IMAGE_REGISTRY used to indicate the registery/group for the operator and bundle
IMAGE_REGISTRY ?= quay.io/medik8s
export IMAGE_REGISTRY

# Use the selected version for image tags.
IMAGE_TAG = v$(VERSION)
export IMAGE_TAG

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle images.
#
# For example, running 'make bundle-build bundle-push' will build and push the bundle image
IMAGE_TAG_BASE ?= $(IMAGE_REGISTRY)/$(OPERATOR_NAME)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:$(IMAGE_TAG)

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:$(IMAGE_TAG)

# Image URL to use all building/pushing image targets
export IMG ?= $(IMAGE_TAG_BASE):$(IMAGE_TAG)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
CONTAINER_TOOL ?= podman
export CONTAINER_TOOL

.PHONY: all
all: manager

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Operands

OPERANDS := nhc snr sbr far mdr nmo
# Checkouts used by update-operand-manifests. Override all with OPERAND_SRC_DIR or one with NHC_PATH etc.
OPERAND_SRC_DIR ?= .cache/operands

.PHONY: update-release-set
update-release-set: yq ## Rewrite release-set.yaml from published images (OPERAND_TAG=release|pinned|latest|<tag>, or NHC_TAG=...).
	YQ=$(YQ) hack/update-release-set.sh

.PHONY: update-operand-manifests
update-operand-manifests: yq ## Copy upstream config/ at the commits in release-set.yaml into config/operands/<k>/upstream, then render.
	YQ=$(YQ) OPERAND_SRC_DIR=$(OPERAND_SRC_DIR) hack/update-operand-manifests.sh

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
	@{ echo '# Generated by make operand-manifests: the operand CRDs shipped in the WAO CSV (kustomize forbids file references outside its root, so it points at the upstream crd directories).'; \
	   echo 'apiVersion: kustomize.config.k8s.io/v1beta1'; echo 'kind: Kustomization'; echo 'resources:'; \
	   for k in $(OPERANDS); do echo "- ../$$k/upstream/config/crd"; done; } > config/operands/crd/kustomization.yaml
	@set -e; for env in $$($(YQ) '[.components[].images | keys | .[]] | .[]' release-set.yaml); do \
	  img=$$($(YQ) ".components[].images.$$env.pinned // \"\"" release-set.yaml | grep . || true); \
	  if ! echo "$$img" | grep -Eq '^.+@sha256:[0-9a-f]{64}$$'; then echo "operand-manifests: release-set.yaml has no pinned digest for $$env"; exit 1; fi; \
	  cur=$$($(YQ) "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$$env\") | .value" config/manager/manager.yaml | grep . || echo __MISSING__); \
	  if [ "$$cur" = __MISSING__ ]; then echo "operand-manifests: $$env not found in config/manager/manager.yaml"; exit 1; fi; \
	  [ "$$cur" = "$$img" ] || \
	  $(YQ) -i "(select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$$env\") | .value) = \"$$img\"" config/manager/manager.yaml; \
	done

.PHONY: bump-operands
bump-operands: update-release-set update-operand-manifests ## update-release-set then update-operand-manifests, then show the diff.
	git status --short release-set.yaml config/operands config/manager internal/operands

PYTHON ?= .venv/bin/python
BUNDLE_CACHE ?= .cache/bundles

.PHONY: python-env
python-env: ## Prepare the default Python environment and its pinned dependencies.

# A custom interpreter is managed by the caller; only bootstrap our local venv.
ifeq ($(PYTHON),.venv/bin/python)
python-env: .venv/.requirements-installed

.venv/bin/python:
	python3 -m venv .venv

.venv/.requirements-installed: hack/requirements.txt .venv/bin/python
	$(PYTHON) -m pip install -r hack/requirements.txt
	touch $@
endif

# Order-only prerequisites keep environment setup out of target freshness checks.
bundles bundle-check catalog-configmap test-offline: | python-env

.PHONY: bundles
bundles: ## Fetch the pinned upstream bundles from release-set.yaml into .cache/bundles.
	$(PYTHON) hack/fetch-bundles.py --release-set release-set.yaml --out $(BUNDLE_CACHE)

.PHONY: bundle-check
bundle-check: ## Verify the generated bundle against the POC contract and release-set.yaml.
	$(PYTHON) hack/check-bundle.py bundle release-set.yaml

CATALOG_NS ?= openshift-marketplace
.PHONY: catalog-configmap
catalog-configmap: bundle-check ## Render the POC ConfigMap-backed CatalogSource into dist/wao-poc-catalog.yaml.
	mkdir -p dist
	$(PYTHON) hack/configmap-catalog.py --bundle bundle --package $(OPERATOR_NAME) --channel $(or $(DEFAULT_CHANNEL),alpha) --name wao-poc-catalog --namespace $(CATALOG_NS) > dist/wao-poc-catalog.yaml

.PHONY: test-offline
test-offline: ## Run every offline Python test and syntax-check the live-cluster scripts (no cluster needed).
	$(PYTHON) -m unittest hack/extract_operand_manifests_test.py hack/configmap_catalog_test.py hack/e2e_runner_test.py hack/build_test.py


##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: goimports ## Run go goimports against code - goimports = go fmt + fixing imports.
	$(GOIMPORTS) -w  ./cmd ./api ./internal

.PHONY: vet
vet: ## Run go vet against code
	go vet ./...

.PHONY: go-tidy
go-tidy: # Run go mod tidy - add missing and remove unused modules.
	go mod tidy

.PHONY: go-vendor
go-vendor:  # Run go mod vendor - make vendored copy of dependencies.
	go mod vendor

.PHONY: go-verify
go-verify: go-tidy go-vendor # Run go mod verify - verify dependencies have expected content
	go mod verify

.PHONY: test-imports
test-imports: sort-imports ## Check for sorted imports
	$(SORT_IMPORTS) .

.PHONY: fix-imports
fix-imports: sort-imports ## Sort imports
	$(SORT_IMPORTS) -w .

.PHONY: verify-no-changes
verify-no-changes: bundle-reset ## verify no there are no un-staged changes and remove unwanted changes to bundle
	./hack/verify-diff.sh

# Run tests
# Use TEST_OPS to pass further options to `go test` (e.g. verbosity and/or -ginkgo.focus)
export TEST_OPS ?=
.PHONY: test
test: test-no-verify-changes verify-no-changes ## Run tests and verify no changes

.PHONY: test-no-verify-changes
test-no-verify-changes: go-verify manifests generate fmt vet test-imports envtest ## Generate and format code, run tests, generate manifests and bundle
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path --bin-dir $(PROJECT_DIR)/testbin)" \
	go test ./internal/controller/... -coverprofile cover.out ${TEST_OPS}

.PHONY: e2e-test
e2e-test: ## Run end to end tests against an already deployed operator
	@# KUBECONFIG must be set to the cluster, and MDR needs to be deployed already
	@#@test -n "${KUBECONFIG}" -o -r ${HOME}/.kube/config || (echo "Failed to find kubeconfig in ~/.kube/config or no KUBECONFIG set"; exit 1)
	@#go test ./e2e -coverprofile cover.out -v -timeout 25m -ginkgo.vv  ${TEST_OPS}
	@echo "not yet implemented"

##@ Build

.PHONY: manager
manager: generate fmt vet ## Build manager binary
	./hack/build.sh ./bin

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

.PHONY: docker-build
docker-build: test-no-verify-changes ## Build docker image with the manager.
	$(CONTAINER_TOOL) build --platform $(PLATFORM) --build-arg VERSION="$(VERSION)" -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

##@ Deployment

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from a cluster
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller in the configured Kubernetes cluster in ~/.kube/config
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## UnDeploy controller from the configured Kubernetes cluster in ~/.kube/config
	$(KUSTOMIZE) build config/default | kubectl delete -f -


##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

.PHONY: controller-gen
CONTROLLER_GEN = $(LOCALBIN)/controller-gen
controller-gen: ## Download controller-gen locally if necessary
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION))


.PHONY: kustomize
KUSTOMIZE = $(LOCALBIN)/kustomize
kustomize: ## Download kustomize locally if necessary
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/$(KUSTOMIZE_API_VERSION)@$(KUSTOMIZE_VERSION))

.PHONY: envtest
ENVTEST = $(LOCALBIN)/setup-envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@$(ENVTEST_VERSION))

.PHONY: goimports
GOIMPORTS = $(LOCALBIN)/goimports
goimports: ## Download goimports locally if necessary.
	$(call go-install-tool,$(GOIMPORTS),golang.org/x/tools/cmd/goimports@$(GOIMPORTS_VERSION))

.PHONY: sort-imports
SORT_IMPORTS = $(LOCALBIN)/sort-imports
sort-imports: ## Download sort-imports locally if necessary.
	$(call go-install-tool,$(SORT_IMPORTS),github.com/slintes/sort-imports@$(SORT_IMPORTS_VERSION))

.PHONY: yq
YQ = $(LOCALBIN)/yq
yq: ## Download yq locally if necessary.
	@$(call go-install-tool,$(YQ),github.com/mikefarah/yq/$(YQ_API_VERSION)@$(YQ_VERSION))

# go-install-tool will 'go install' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-install-tool
@[ -f $(1) ] || { \
set -e ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin GOFLAGS='' go install $(2) ;\
}
endef

.PHONY: opm
OPM_DIR = $(LOCALBIN)/opm
OPM = $(OPM_DIR)/$(OPM_VERSION)/opm
opm: ## Download opm locally if necessary.
	$(call operator-framework-tool, $(OPM), $(OPM_DIR),https://github.com/operator-framework/operator-registry/releases/download/$(OPM_VERSION)/$${OS}-$${ARCH}-opm )

.PHONY: operator-sdk
OPERATOR_SDK_DIR ?= $(LOCALBIN)/operator-sdk
OPERATOR_SDK = $(OPERATOR_SDK_DIR)/$(OPERATOR_SDK_VERSION)/operator-sdk
operator-sdk: ## Download operator-sdk locally if necessary.
	$(call operator-framework-tool, $(OPERATOR_SDK), $(OPERATOR_SDK_DIR),github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$${OS}_$${ARCH})

# operator-framework-tool will delete old package $2, then download $3 to $1.
define operator-framework-tool
@[ -f $(1) ] || { \
	set -e ;\
	rm -rf $(2) ;\
	mkdir -p $(dir $(1)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	echo "Downloading $(3)" ;\
	curl -sSLo $(1) $(3) ;\
	chmod +x $(1) ;\
	}
endef

##@ Working with Bundle

.PHONY: bundle
bundle: verify-previous-version verify-skip-range ## Generate bundle manifests and metadata, then validate generated files.
	# Validate before starting generation, including under parallel Make.
	$(MAKE) manifests kustomize operator-sdk
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build $(MANIFESTS_DIR) | $(OPERATOR_SDK) generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(MAKE) bundle-validate

.PHONY: bundle-k8s
bundle-k8s: bundle ## Alias for bundle target

## Some addition to bundle creation in the bundle
DEFAULT_ICON_BASE64 := $(shell base64 < "${BLUE_ICON_PATH}" | tr -d '\n')
export ICON_BASE64 ?= ${DEFAULT_ICON_BASE64}
export CSV=./bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml

.PHONY: bundle-update
bundle-update: verify-previous-version verify-skip-range yq ## Update CSV fields and validate the bundle directory
	@if [ -n "$(PREVIOUS_VERSION)" ]; then \
		$(YQ) -i '.spec.replaces = "$(OPERATOR_NAME).v$(PREVIOUS_VERSION)"' "$(CSV)"; \
	else \
		$(YQ) -i 'del(.spec.replaces)' "$(CSV)"; \
	fi
	@if [ -n "$(SKIP_RANGE_LOWER)" ]; then \
		$(YQ) -i '.metadata.annotations."olm.skipRange" = ">=$(SKIP_RANGE_LOWER) <$(VERSION)"' "$(CSV)"; \
	else \
		$(YQ) -i 'del(.metadata.annotations."olm.skipRange")' "$(CSV)"; \
	fi
	$(YQ) -i '.spec.icon = [{"base64data": strenv(ICON_BASE64), "mediatype": "image/png"}]' "$(CSV)"
	$(MAKE) bundle-validate

.PHONY: bundle-reset
bundle-reset: yq ## Revert all version or build date related changes
	$(MAKE) bundle VERSION=$(DEFAULT_VERSION) IMAGE_TAG=v$(DEFAULT_VERSION) IMG=$(IMAGE_TAG_BASE):v$(DEFAULT_VERSION) PREVIOUS_VERSION=$(DEFAULT_PREVIOUS_VERSION) SKIP_RANGE_LOWER=$(DEFAULT_SKIP_RANGE_LOWER)
	$(MAKE) bundle-update VERSION=$(DEFAULT_VERSION) PREVIOUS_VERSION=$(DEFAULT_PREVIOUS_VERSION) SKIP_RANGE_LOWER=$(DEFAULT_SKIP_RANGE_LOWER)
	$(YQ) -i '.metadata.annotations.createdAt = ""' "$(CSV)"
	$(MAKE) bundle-validate VERSION=$(DEFAULT_VERSION) IMAGE_TAG=v$(DEFAULT_VERSION) PREVIOUS_VERSION=$(DEFAULT_PREVIOUS_VERSION) SKIP_RANGE_LOWER=$(DEFAULT_SKIP_RANGE_LOWER)

.PHONY: verify-previous-version
verify-previous-version: ## Require any previous version to be older than the candidate.
	@if [ -n "$(PREVIOUS_VERSION)" ]; then \
		if [ "$(PREVIOUS_VERSION)" = "$(VERSION)" ] || ! printf '%s\n' "$(PREVIOUS_VERSION)" "$(VERSION)" | sort -V -C 2>/dev/null; then \
			echo "Error: VERSION must be greater than PREVIOUS_VERSION"; \
			exit 1; \
		fi; \
	fi

.PHONY: verify-skip-range
verify-skip-range: ## Require any skip-range lower bound to be older than the candidate.
	@if [ -n "$(SKIP_RANGE_LOWER)" ]; then \
		if [ "$(SKIP_RANGE_LOWER)" = "$(VERSION)" ] || ! printf '%s\n' "$(SKIP_RANGE_LOWER)" "$(VERSION)" | sort -V -C 2>/dev/null; then \
			echo "Error: VERSION must be greater than SKIP_RANGE_LOWER"; \
			exit 1; \
		fi; \
	fi

.PHONY: bundle-community-okd
bundle-community-okd: bundle yq ## Update displayName field in the bundle's CSV
	$(YQ) -i '.spec.displayName = "Workload Availability Operator - Community Edition"' "$(CSV)"
	$(MAKE) add-ocp-annotations
	echo -e "\n  # Annotations for OCP\n  com.redhat.openshift.versions: \"v${OCP_VERSION}\"" >> bundle/metadata/annotations.yaml
	$(MAKE) bundle-update


.PHONY: add-ocp-annotations
add-ocp-annotations: yq ## Add OCP annotations
	$(YQ) -i '.metadata.annotations."operators.openshift.io/valid-subscription" = "[\"OpenShift Kubernetes Engine\", \"OpenShift Container Platform\", \"OpenShift Platform Plus\"]"' ${CSV}
	# new infrastructure annotations see https://docs.engineering.redhat.com/display/CFC/Best_Practices#Best_Practices-(New)RequiredInfrastructureAnnotations
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/disconnected" = "true"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/fips-compliant" = "false"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/proxy-aware" = "false"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/tls-profiles" = "true"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-aws" = "false"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-azure" = "false"' ${CSV}
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-gcp" = "false"' ${CSV}


.PHONY: bundle-validate
bundle-validate: operator-sdk ## Validate the bundle directory with additional validators (suite=operatorframework), such as Kubernetes deprecated APIs (https://kubernetes.io/docs/reference/using-api/deprecation-guide/) based on bundle.CSV.Spec.MinKubeVersion
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional suite=operatorframework

.PHONY: bundle-build
bundle-build: bundle ## Build the bundle image.
	$(MAKE) bundle-update
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(CONTAINER_TOOL) push $(BUNDLE_IMG)

.PHONY: bundle-run
OPERATOR_NAMESPACE ?= openshift-workload-availability
bundle-run: operator-sdk ## Run bundle image
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) run bundle $(BUNDLE_IMG)

.PHONY: bundle-run-update
bundle-run-update: operator-sdk ## Upgrade bundle image
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) run bundle-upgrade $(BUNDLE_IMG)

.PHONY: bundle-cleanup
bundle-cleanup: operator-sdk ## Remove bundle installed via bundle-run
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) cleanup $(OPERATOR_NAME)

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

.PHONY: catalog-source
catalog-source: yq ## Write dist/catalogsource.yaml pointing at CATALOG_IMG.
	@test -n "$(CATALOG_IMG)" || { echo "catalog-source: set CATALOG_IMG"; exit 1; }
	mkdir -p dist
	$(YQ) '.spec.image = "$(CATALOG_IMG)"' config/catalog/catalogsource.yaml > dist/catalogsource.yaml
	@grep -q CATALOG_IMG_PLACEHOLDER dist/catalogsource.yaml && { echo "catalog-source: placeholder left"; exit 1; } || true

##@ Targets used by CI

.PHONY: container-build
container-build: ## Build containers
	$(MAKE) docker-build bundle-build

.PHONY: container-push
container-push: ## Push containers (NOTE: catalog can't be built before bundle is pushed)
	$(MAKE) docker-push bundle-push catalog-build catalog-push

# Shared dev environment
# Uses a local sibling checkout if available (e.g. ../tools),
# otherwise downloads the tools repo into .tools/ on first dev-* target use.
#
# IMPORTANT: Do NOT use $(shell git clone ...) here — $(shell) executes at
# Makefile parse time, so any make invocation (make build, make test, make help)
# would trigger a git clone. The dev-% fallback rule below is lazy: the clone
# only runs when a dev-* target is actually invoked.
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_MK := $(TOOLS_DIR)/dev/dev.mk
ifeq ($(wildcard $(DEV_MK)),)
  TOOLS_DIR := $(shell pwd)/.tools
  DEV_MK := $(TOOLS_DIR)/dev/dev.mk
endif
-include $(DEV_MK)
ifeq ($(wildcard $(DEV_MK)),)
dev-%:
	@echo "Downloading medik8s/tools into $(TOOLS_DIR)..."
	@if [ -d $(TOOLS_DIR) ]; then \
		if [ -f $(TOOLS_DIR)/.managed-by-makefile ]; then \
			echo "  Removing stale $(TOOLS_DIR)..."; rm -rf $(TOOLS_DIR); \
		else \
			echo "Error: $(TOOLS_DIR) exists but was not created by this Makefile (missing .managed-by-makefile sentinel)."; \
			echo "       Remove it manually or set TOOLS_DIR to a valid medik8s/tools checkout."; exit 1; \
		fi; \
	fi
	@git clone --depth 1 https://github.com/medik8s/tools.git $(TOOLS_DIR)
	@touch $(TOOLS_DIR)/.managed-by-makefile
	@test -f $(DEV_MK) || { echo "Error: $(DEV_MK) not found after clone."; exit 1; }
	@$(MAKE) $@
endif
