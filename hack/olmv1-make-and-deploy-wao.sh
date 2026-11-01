#!/usr/bin/env bash
# Build, push and install the Workload Availability Operator (WAO) through OLM v1
# (ClusterCatalog + ClusterExtension). The OLM v0 equivalent is hack/wao-make_and_deploy.sh.
#
# Needs a cluster with OLM v1 serving olm.operatorframework.io/v1 (OCP 5.0 tested). Do not
# install the same package through OLM v0 at the same time: remove any v0 install first with
# hack/wao-purge.sh, or the ClusterExtension fails on objects it does not own.
#
# Set SKIP_BUILD=1 to reuse images already pushed for $VERSION and only (re)install.
#
# Usage, from anywhere:
#   ./hack/olmv1-make-and-deploy-wao.sh

# Stop on the first failed command, on unset variables, and on failures inside pipelines.
set -euo pipefail

# Run from the repo root no matter where the script was invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export REG="${REG:-quay.io/jwmatthews}"
export VERSION="${VERSION:-0.1.0-20261031b}"
export IMG="${IMG:-$REG/workload-availability-operator:v$VERSION}"
export BUNDLE_IMG="${BUNDLE_IMG:-$REG/workload-availability-operator-bundle:v$VERSION}"
export CATALOG_IMG="${CATALOG_IMG:-$REG/workload-availability-operator-catalog:v$VERSION}"
export KUBECONFIG="${KUBECONFIG:-$PWD/jmatthews-rhwa-ocp5-rc6.kubeconfig}"
SKIP_BUILD="${SKIP_BUILD:-0}"

NS=openshift-workload-availability
PKG=workload-availability-operator
CATALOG=wao-poc-catalog
EXTENSION=workload-availability-operator
DEPLOYMENT=workload-availability-operator-controller-manager

# Print the ClusterExtension and ClusterCatalog state when a wait times out.
diagnose() {
  echo "---- diagnostics ----" >&2
  oc get clustercatalog "$CATALOG" -o jsonpath='{range .status.conditions[*]}catalog {.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
  oc get clusterextension "$EXTENSION" -o jsonpath='{range .status.conditions[*]}extension {.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
  oc -n "$NS" get deploy,pods >&2 || true
}
trap 'rc=$?; [ $rc -eq 0 ] || diagnose; exit $rc' EXIT

# Confirm KUBECONFIG reaches the cluster before spending time on builds.
if ! oc whoami; then
  echo "ERROR: 'oc whoami' failed with KUBECONFIG=$KUBECONFIG" >&2
  exit 1
fi
echo "Using cluster: $(oc whoami --show-server)"

if ! oc api-resources --api-group=olm.operatorframework.io -o name | grep -qx 'clusterextensions.olm.operatorframework.io'; then
  echo "ERROR: this cluster does not serve OLM v1 (no clusterextensions.olm.operatorframework.io)" >&2
  exit 1
fi

# An OLM v0 install of the same package would own the CRDs and RBAC the ClusterExtension needs.
if oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.spec.name}{"\n"}{end}' 2>/dev/null | grep -qx "$PKG"; then
  echo "ERROR: an OLM v0 Subscription for $PKG exists; remove it first (hack/wao-purge.sh)" >&2
  exit 1
fi

if [ "$SKIP_BUILD" != "1" ]; then
  make docker-build
  make docker-push

  make bundle-build
  make bundle-push

  grep -n 'workload-availability-operator:' bundle/manifests/*.clusterserviceversion.yaml

  make catalog-build
  make catalog-push

  grep -n '^schema:\|^image:\|^name:' catalog/index.yaml
fi

# Pin the ClusterCatalog to the digest just pushed. A digest changes on every rebuild, so
# catalogd unpacks new content immediately even when the tag is reused (OLM v0 needed the
# catalog pod deleted for that).
CATALOG_DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$CATALOG_IMG")
CATALOG_REF="${CATALOG_IMG%:*}@${CATALOG_DIGEST}"
echo "Catalog image: $CATALOG_REF"

make cluster-catalog CATALOG_IMG="$CATALOG_REF"   # writes dist/clustercatalog.yaml
cat dist/clustercatalog.yaml
oc apply -f dist/clustercatalog.yaml

echo "Waiting for catalogd to unpack $CATALOG_REF..."
oc wait "clustercatalog/$CATALOG" \
  --for=jsonpath='{.status.resolvedSource.image.ref}'="$CATALOG_REF" --timeout=5m
oc wait "clustercatalog/$CATALOG" --for=condition=Serving=True --timeout=5m

# The bundle image ref in the catalog is a tag. If the installed bundle already has this version,
# OLM v1 sees nothing new and keeps running the old image even if the tag was rebuilt.
INSTALLED=$(oc get clusterextension "$EXTENSION" -o jsonpath='{.status.install.bundle.version}' 2>/dev/null || true)
if [ "$INSTALLED" = "$VERSION" ] && [ "$SKIP_BUILD" != "1" ]; then
  echo "WARN: $PKG $VERSION is already installed; a rebuilt image with the same VERSION is NOT" >&2
  echo "      rolled out. Bump VERSION, or run hack/wao-olmv1-purge.sh and deploy again." >&2
fi

# Namespace and ClusterExtension (the OLM v1 replacement for OperatorGroup + Subscription).
oc apply -f config/catalog/olmv1/clusterextension.yaml

echo "Waiting for OLM v1 to install $PKG $VERSION..."
oc wait "clusterextension/$EXTENSION" \
  --for=jsonpath='{.status.install.bundle.version}'="$VERSION" --timeout=10m
oc wait "clusterextension/$EXTENSION" --for=condition=Installed=True --timeout=10m
oc -n "$NS" rollout status "deploy/$DEPLOYMENT" --timeout=10m

# WAO creates the singleton WorkloadAvailabilityConfig at startup.
echo "Waiting for WorkloadAvailabilityConfig/cluster..."
for _ in $(seq 1 60); do
  oc get workloadavailabilityconfig cluster >/dev/null 2>&1 && break
  sleep 5
done

oc get clusterextension "$EXTENSION"
oc -n "$NS" get deploy,pods
oc get workloadavailabilityconfig cluster
