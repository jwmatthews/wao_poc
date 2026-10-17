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
