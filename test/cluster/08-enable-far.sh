#!/usr/bin/env bash
# test/cluster/08-enable-far.sh — WAO-INST-08: enable FAR. No fencing: only server dry-run templates.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-08 enable FAR"
set_state 08 fenceAgentsRemediation Enabled
wait_for 300 "FAR manager Available" deployment_available fence-agents-remediation-controller-manager
for w in validatingwebhookconfiguration/fence-agents-remediation-validating-webhook-configuration \
         mutatingwebhookconfiguration/fence-agents-remediation-mutating-webhook-configuration; do
  wait_for 180 "CA bundles injected in $w" ca_injected "$w"
done
four_webhooks() {
  local n; n=$(webhook_names) || return 1
  printf '%s\n' "$n" | grep -qx mfenceagentsremediation.kb.io && printf '%s\n' "$n" | grep -qx mfenceagentsremediationtemplate.kb.io &&
    printf '%s\n' "$n" | grep -qx vfenceagentsremediation.kb.io && printf '%s\n' "$n" | grep -qx vfenceagentsremediationtemplate.kb.io
}
expect "all four FAR webhooks registered" four_webhooks
wait_for 180 "status phase Available" phase_is fenceAgentsRemediation Available
expect "status admissionReady true" field_is fenceAgentsRemediation admissionReady true
expect "every rendered FAR operand object exists" operands_present far
expect "service-ca created the webhook serving Secret with tls.crt and tls.key (key names only)" \
  secret_has_keys "$NS" fence-agents-remediation-webhook-server-cert tls.crt tls.key

template() { # template NAME AGENT : print a FenceAgentsRemediationTemplate manifest
  cat <<YAML
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  name: $1
  namespace: ${NS}
spec:
  template:
    spec:
      agent: $2
YAML
}
expect "unknown fence agent rejected (dry-run)" dry_run_rejected 08-admission-unknown-agent create < <(template wao-inst-08-bad fence_wao_does_not_exist)
expect "rejection names the unsupported agent" grep -q "unsupported fence agent" <<<"$DRY_RUN_OUT"
ann=$(template wao-inst-08-ok fence_ipmilan | k create --dry-run=server -o jsonpath='{.metadata.annotations.remediation\.medik8s\.io/multiple-templates-support}' -f - 2>"${RUN_DIR}/raw/08-admission-ok.stderr.txt" || true)
expect "mutating webhook reachable (dry-run fence_ipmilan template gained multiple-templates annotation)" test "$ann" = "true"
expect "no FenceAgentsRemediationTemplate was persisted" none_found fenceagentsremediationtemplates -A
expect "no FenceAgentsRemediation objects exist" none_found fenceagentsremediations -A
record 08-manager-logs logs deployment/fence-agents-remediation-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 08
