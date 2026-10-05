#!/usr/bin/env bash
# test/olmv1/18-uninstall.sh — remove everything experiment 0001 created, in reverse order.
# WARNING: deleting a ClusterExtension deletes its CRDs and therefore every CR stored in them
# (OCP 4.22 docs, "Deleting an Operator"). Acceptable only on a disposable cluster with no
# customer data. SNR is removed first so its node agents stop before anything else goes.
# Set KEEP_NS=1 to keep the namespace. Records what was deleted and what was left over.
source "$(dirname "$0")/lib.sh"
echo "== 0001-18 uninstall"
snapshot 18-before
order="snr sbr far mdr nmo nhc"
for key in $order; do
  pkg=$(op_package "$key")
  if found clusterextension "$pkg" 2>/dev/null; then
    echo "-- deleting ClusterExtension $pkg"
    record "18-$key-delete-ce" delete clusterextension "$pkg" --timeout=300s >/dev/null || echo "WARN: delete of $pkg returned non-zero" >&2
    wait_for 300 "ClusterExtension $pkg gone" absent clusterextension "$pkg" || echo "WARN: $pkg still present" >&2
  fi
  for crd in $(op_crds "$key"); do
    if ! absent crd "$crd"; then echo "LEFTOVER: CRD $crd survived ClusterExtension deletion" | tee -a "${RUN_DIR}/leftovers.txt"; fi
  done
  for f in 20-clusterrolebinding 10-clusterrole 00-serviceaccount; do
    [ -f "$(dirname "$0")/rbac/$key/$f.yaml" ] && record "18-$key-delete-$f" delete -f "$(dirname "$0")/rbac/$key/$f.yaml" --ignore-not-found >/dev/null || true
  done
done
# Agents: SNR/SBR DaemonSets live in the install namespace and go with it; confirm none remain.
if [ -z "${KEEP_NS:-}" ]; then
  record 18-delete-ns delete namespace "$NS" --ignore-not-found --timeout=300s >/dev/null || true
  wait_for 300 "namespace $NS gone" absent namespace "$NS" || echo "LEFTOVER: namespace $NS" | tee -a "${RUN_DIR}/leftovers.txt"
fi
for w in $(k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -i medik8s || true); do
  echo "LEFTOVER: $w" | tee -a "${RUN_DIR}/leftovers.txt"
done
if ! absent namespace medik8s-leases; then echo "LEFTOVER: namespace medik8s-leases (created at runtime by NHC/NMO; delete by hand if unwanted)" | tee -a "${RUN_DIR}/leftovers.txt"; fi
snapshot 18-after
outcome 0001-18 PASS "uninstall ran; see leftovers.txt"
echo "== done; leftovers: $(wc -l < "${RUN_DIR}/leftovers.txt" 2>/dev/null || echo 0)"
