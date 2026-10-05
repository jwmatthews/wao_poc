#!/usr/bin/env bash
# test/cluster/06-enable-snr.sh — WAO-INST-06: enable SNR. Starts SNR node agents on every eligible node
# (design brief D3). Admission is probed with server dry-run only; no SelfNodeRemediation is created.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-06 enable SNR"
set_state 06 selfNodeRemediation Enabled
wait_for 300 "SNR manager Available" deployment_available self-node-remediation-controller-manager
for w in validatingwebhookconfiguration/self-node-remediation-validating-webhook-configuration \
         mutatingwebhookconfiguration/self-node-remediation-mutating-webhook-configuration; do
  wait_for 180 "CA bundles injected in $w" ca_injected "$w"
done
four_webhooks() {
  local n; n=$(webhook_names) || return 1
  printf '%s\n' "$n" | grep -qx mselfnoderemediationtemplate.kb.io && printf '%s\n' "$n" | grep -qx vselfnoderemediation.kb.io &&
    printf '%s\n' "$n" | grep -qx vselfnoderemediationconfig.kb.io && printf '%s\n' "$n" | grep -qx vselfnoderemediationtemplate.kb.io
}
expect "all four SNR webhooks registered" four_webhooks
wait_for 180 "status phase Available" phase_is selfNodeRemediation Available
expect "status admissionReady true" field_is selfNodeRemediation admissionReady true
expect "every rendered SNR operand object exists" operands_present snr
expect "service-ca created the webhook serving Secret with tls.crt and tls.key (key names only)" \
  secret_has_keys "$NS" self-node-remediation-webhook-server-cert tls.crt tls.key

wait_for 120 "SNR created its default config" found selfnoderemediationconfig self-node-remediation-config -n "$NS"
wait_for 120 "SNR created its default template" found selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
wait_for 120 "SNR created its peer certificate Secret (existence only)" found secret self-node-remediation-certificates -n "$NS"
ds_ready() {
  jcheck 'o["status"].get("desiredNumberScheduled", 0) > 0 and o["status"].get("numberReady") == o["status"]["desiredNumberScheduled"]' \
    get daemonset self-node-remediation-ds -n "$NS"
}
wait_for 300 "agent DaemonSet ready on every scheduled node" ds_ready
record 06-ds get daemonset self-node-remediation-ds -n "$NS" -o json >/dev/null
expect "no SelfNodeRemediation exists" none_found selfnoderemediations -A

expect "second SNR config rejected (dry-run)" dry_run_rejected 06-admission-second-config apply <<YAML
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationConfig
metadata:
  name: second-config
  namespace: ${NS}
spec: {}
YAML
expect "rejection came from vselfnoderemediationconfig.kb.io" grep -q "vselfnoderemediationconfig.kb.io" <<<"$DRY_RUN_OUT"
expect "no SNR config named second-config exists" absent selfnoderemediationconfig second-config -n "$NS"

snr_template() {
  cat <<YAML
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: wao-inst-06-probe
  namespace: ${NS}
spec:
  template:
    spec: {}
YAML
}
ann=$(snr_template | k create --dry-run=server -o jsonpath='{.metadata.annotations.remediation\.medik8s\.io/multiple-templates-support}' -f - 2>"${RUN_DIR}/raw/06-admission-template.stderr.txt" || true)
expect "mutating webhook reachable (dry-run template gained multiple-templates annotation)" test "$ann" = "true"
expect "no SNR template named wao-inst-06-probe exists" absent selfnoderemediationtemplate wao-inst-06-probe -n "$NS"
record 06-manager-logs logs deployment/self-node-remediation-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 06
