#!/usr/bin/env bash
# test/cluster/07-enable-sbr.sh — WAO-INST-07: enable SBR. SBR serves no webhooks. A StorageBasedRemediationConfig
# would create agents, PVCs and Jobs, so it is only ever created with server dry-run.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-07 enable SBR"
set_state 07 storageBasedRemediation Enabled
wait_for 300 "SBR manager Available" deployment_available sbr-operator-controller-manager
wait_for 180 "status phase Available" phase_is storageBasedRemediation Available
expect "status has no admissionReady field" field_is storageBasedRemediation admissionReady null
expect "every rendered SBR operand object exists" operands_present sbr
expect "ServiceAccount sbr-operator-sbr-agent exists" found serviceaccount sbr-operator-sbr-agent -n "$NS"
expect "ClusterRoleBinding sbr-operator-sbr-agent-rolebinding subjects use namespace $NS (D9)" \
  jcheck '[s for s in o["subjects"] if s["kind"] == "ServiceAccount"] and all(s.get("namespace") == os.environ["NS"] for s in o["subjects"] if s["kind"] == "ServiceAccount")' \
  get clusterrolebinding sbr-operator-sbr-agent-rolebinding
expect "no SBR DaemonSet (only SNR's agent DaemonSet may exist)" \
  jcheck 'all(i["metadata"]["name"] == "self-node-remediation-ds" for i in o["items"])' get daemonset -n "$NS"
expect "no PVC in $NS" none_found pvc -n "$NS"
expect "no Job in $NS" none_found job -n "$NS"

sbr_config() {
  cat <<YAML
apiVersion: storage-based-remediation.medik8s.io/v1alpha1
kind: StorageBasedRemediationConfig
metadata:
  name: wao-inst-07-probe
  namespace: ${NS}
spec: {}
YAML
}
code=0
out=$(sbr_config | k create --dry-run=server -f - 2>&1) || code=$?
printf '%s\n' "$out" > "${RUN_DIR}/raw/07-dry-run-config.txt"
expect "dry-run StorageBasedRemediationConfig create accepted" test "$code" -eq 0
expect "the dry-run config was not persisted" none_found storagebasedremediationconfigs -A
record 07-manager-logs logs deployment/sbr-operator-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 07
