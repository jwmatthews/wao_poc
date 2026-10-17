#!/usr/bin/env bash
# Install WAO through classic OLM from the FBC CatalogSource written by hack/cluster-build.sh.
# Usage: hack/cluster-install.sh /path/to/kubeconfig
set -euo pipefail
KC=${1:?usage: $0 KUBECONFIG}
KC=$(cd "$(dirname "$KC")" 2>/dev/null && pwd)/$(basename "$KC")
[ -f "$KC" ] || { echo "kubeconfig not found: $KC" >&2; exit 1; }
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
