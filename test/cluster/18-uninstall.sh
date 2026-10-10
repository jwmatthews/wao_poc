#!/usr/bin/env bash
# test/cluster/18-uninstall.sh — WAO-INST-18: uninstall WAO, record what remains, then clean the cluster back to a
# state that passes WAO-INST-00 again. Deliberately keeps the image build namespace ($BUILD_NS).
#
# Delete the config, the SNR objects, then the ClusterExtension (which removes the thirteen CRDs and every CR), the
# installer RBAC, the ClusterCatalog and the namespace.
#
# Cleanup keeps going after a failed step so one stuck object does not leave everything behind; the case fails
# if any step failed. Deleting the SNR config garbage-collects the SNR agent DaemonSet (agents stop).
source "$(dirname "$0")/lib.sh"
set +e   # explicit failure tracking below
echo "== WAO-INST-18 uninstall and cleanup"
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
leftover() { # leftover DESCRIPTION ARGS... : print LEFTOVER when `k get ARGS` finds something
  local desc="$1"; shift
  found "$@" >/dev/null 2>&1 && echo "LEFTOVER: $desc"
  return 0
}
# clear_finalizers RESOURCE NAME [k args] : last resort for an object whose controller is gone.
clear_finalizers() {
  echo "NOTE: removing stale finalizers from $1/$2 (its controller is no longer running)"
  record "18-clear-finalizers-$1" patch "$1" "$2" "${@:3}" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null
}

snapshot 18-before

# 1. Delete the config while WAO still runs, so its finalizer completes (uninstall order: config, then CSV).
if found wac cluster >/dev/null 2>&1; then
  record 18-delete-wac delete workloadavailabilityconfig cluster --wait=false >/dev/null
  wait_for 180 "config deleted by WAO's finalizer" absent wac cluster || echo "note: config still present; finalizer cleared after uninstall"
fi

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

# 3. Record what remains before cleaning up.
record 18-remaining-crds get crd -o name >/dev/null 2>&1
record 18-remaining-ns get all,secrets,configmaps,serviceaccounts -n "$NS" -o name >/dev/null 2>&1
for c in $ALL_CRDS; do leftover "CRD $c" crd "$c"; done
leftover "WorkloadAvailabilityConfig cluster" wac cluster
leftover "SNR agent DaemonSet self-node-remediation-ds" daemonset self-node-remediation-ds -n "$NS"
leftover "SelfNodeRemediationConfig self-node-remediation-config" selfnoderemediationconfig self-node-remediation-config -n "$NS"
leftover "SelfNodeRemediationTemplate self-node-remediation-automatic-strategy-template" selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
leftover "Secret self-node-remediation-certificates" secret self-node-remediation-certificates -n "$NS"
leftover "ClusterRole node-healthcheck-operator-aggregation" clusterrole node-healthcheck-operator-aggregation
leftover "ClusterRoleBinding node-healthcheck-operator-aggregation" clusterrolebinding node-healthcheck-operator-aggregation
leftover "ConsolePlugin node-remediation-console-plugin" consoleplugin node-remediation-console-plugin
leftover "namespace medik8s-leases" namespace medik8s-leases
leftover "cluster-scoped objects labelled managed-by WAO" clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/managed-by=workload-availability-operator

# 4. Clean up.
if found wac cluster >/dev/null 2>&1; then
  clear_finalizers workloadavailabilityconfig cluster
  wait_for 60 "config gone" absent wac cluster || fail "config still present"
fi
record 18-delete-snr-secret delete secret self-node-remediation-certificates -n "$NS" --ignore-not-found >/dev/null || fail "delete SNR Secret"

# shellcheck disable=SC2086
record 18-delete-crds delete crd $ALL_CRDS --ignore-not-found --wait=false >/dev/null || fail "delete CRDs"
all_crds_gone() { local c; for c in $ALL_CRDS; do absent crd "$c" || return 1; done; }
wait_for 300 "all thirteen CRDs gone" all_crds_gone || fail "CRDs still present"

record 18-delete-nhc-aggregation delete clusterrole,clusterrolebinding node-healthcheck-operator-aggregation --ignore-not-found >/dev/null || fail "delete NHC aggregation role/binding"
if k api-resources --api-group=console.openshift.io -o name 2>/dev/null | grep -q '^consoleplugins'; then
  record 18-delete-consoleplugin delete consoleplugin node-remediation-console-plugin --ignore-not-found >/dev/null || fail "delete ConsolePlugin"
fi
record 18-delete-wao-labelled delete clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l app.kubernetes.io/managed-by=workload-availability-operator --ignore-not-found >/dev/null || fail "delete WAO-labelled cluster objects"
if found namespace medik8s-leases >/dev/null 2>&1; then
  record 18-delete-leases-ns delete namespace medik8s-leases --wait=false >/dev/null || fail "delete medik8s-leases"
  wait_for 300 "medik8s-leases gone" absent namespace medik8s-leases || fail "medik8s-leases still present"
fi

record 18-delete-clustercatalog delete clustercatalog "$CLUSTERCATALOG" --ignore-not-found --wait=false >/dev/null || fail "delete ClusterCatalog"
wait_for 120 "ClusterCatalog gone" absent clustercatalog "$CLUSTERCATALOG" || fail "ClusterCatalog still present"
# On OpenShift 4.18-4.22 operator-controller needs the installer ServiceAccount to finish an uninstall.
if absent clusterextension "$CE_NAME"; then
  for f in 20-clusterrolebinding 10-clusterrole 00-serviceaccount; do
    record "18-delete-installer-$f" delete -f "$OLMV1_DIR/wao/$f.yaml" --ignore-not-found >/dev/null || fail "delete installer $f"
  done
else
  echo "LEFTOVER: installer RBAC kept because ClusterExtension $CE_NAME still exists"
  fail "ClusterExtension still present; installer RBAC kept"
fi

record 18-delete-namespace delete namespace "$NS" --ignore-not-found --wait=false >/dev/null || fail "delete namespace"
wait_for 600 "namespace $NS gone" absent namespace "$NS" || fail "namespace $NS still present"

# 5. Deliberate leftovers.
if found namespace "$BUILD_NS" >/dev/null 2>&1; then
  echo "LEFTOVER: namespace $BUILD_NS kept deliberately (WAO image build and ImageStream; delete manually when done)"
fi

# 6. The cluster passes preflight again.
expect "ClusterExtension gone" absent clusterextension "$CE_NAME" || rc=1
expect "no WAO-labelled cluster-scoped object remains" none_found clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/managed-by=workload-availability-operator || rc=1
if bash "$(dirname "$0")/00-preflight.sh" >"${RUN_DIR}/raw/18-final-preflight.log" 2>&1; then
  echo "PASS: final preflight (WAO-INST-00) passes again"
else
  grep -E '^(FAIL|TIMEOUT):' "${RUN_DIR}/raw/18-final-preflight.log" >&2
  fail "final preflight (WAO-INST-00) passes again"
fi
exit $rc
