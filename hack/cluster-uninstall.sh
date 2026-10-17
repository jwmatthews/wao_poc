#!/usr/bin/env bash
# Remove the WAO install created by hack/cluster-install.sh. Leaves the build namespace alone.
# Usage: hack/cluster-uninstall.sh /path/to/kubeconfig
set -euo pipefail
KC=${1:?usage: $0 KUBECONFIG}
KC=$(cd "$(dirname "$KC")" 2>/dev/null && pwd)/$(basename "$KC")
[ -f "$KC" ] || { echo "kubeconfig not found: $KC" >&2; exit 1; }
NS=openshift-workload-availability
oc() { command oc --kubeconfig="$KC" "$@"; }
oc delete workloadavailabilityconfig cluster --ignore-not-found --timeout=120s || true
csv=$(oc get subscription workload-availability-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
oc delete subscription workload-availability-operator -n "$NS" --ignore-not-found
[ -n "$csv" ] && oc delete csv "$csv" -n "$NS" --ignore-not-found
oc delete operatorgroup workload-availability -n "$NS" --ignore-not-found
oc delete catalogsource wao-poc-catalog -n openshift-marketplace --ignore-not-found
echo "WAO removed; CRDs are kept (OLM does not delete them). Delete them only when the cluster is being reset."
