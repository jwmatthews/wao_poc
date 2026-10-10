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
