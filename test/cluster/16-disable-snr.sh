#!/usr/bin/env bash
# test/cluster/16-disable-snr.sh — WAO-INST-16: manager-level disable of SNR (D2, D5). Agents keep running and the
# status says so. Admission checks are server dry-run only.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-16 disable SNR (manager level)"
set_state 16 selfNodeRemediation Disabled
wait_for 180 "selfNodeRemediation phase DisableIncomplete" phase_is selfNodeRemediation DisableIncomplete
wait_for 180 "SNR operand objects removed" operands_absent snr
expect "every rendered SNR object is gone, including both webhook configurations" operands_absent snr
expect "nothing labelled component=selfNodeRemediation remains" labelled_absent selfNodeRemediation
expect "no SNR webhook name is registered" no_webhook_matching selfnoderemediation
wait_for 180 "SNR manager pods gone" none_found pods -n "$NS" -l workloadavailability.medik8s.io/component=selfNodeRemediation

expect "agent DaemonSet self-node-remediation-ds still running" \
  jcheck 'o["status"].get("numberReady", 0) > 0' get daemonset self-node-remediation-ds -n "$NS"
expect "SelfNodeRemediationConfig retained" found selfnoderemediationconfig self-node-remediation-config -n "$NS"
expect "SelfNodeRemediationTemplate retained" found selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
expect "Secret self-node-remediation-certificates retained (existence only)" found secret self-node-remediation-certificates -n "$NS"

expect "retainedResources names the DaemonSet and the config" jcheck '
[c for c in o["status"]["components"] if c["name"] == "selfNodeRemediation"
 and "apps/v1 DaemonSet " + os.environ["NS"] + "/self-node-remediation-ds" in (c.get("retainedResources") or [])
 and "self-node-remediation.medik8s.io/v1alpha1 SelfNodeRemediationConfig " + os.environ["NS"] + "/self-node-remediation-config" in (c.get("retainedResources") or [])]' \
  get wac cluster
record 16-retained get wac cluster -o jsonpath='{.status.components[?(@.name=="selfNodeRemediation")]}' >/dev/null
expect "Available=True reason DisableIncomplete" \
  jcheck '[c for c in o["status"]["conditions"] if c["type"] == "Available" and c["status"] == "True" and c["reason"] == "DisableIncomplete"]' get wac cluster
expect "admissionReady false" field_is selfNodeRemediation admissionReady false

# D2: with the webhooks removed, admission no longer blocks the component's objects. Dry-run only.
dry_delete() { # dry_delete LABEL RESOURCE NAME
  local code=0 out
  out=$(k delete "$2" "$3" -n "$NS" --dry-run=server 2>&1) || code=$?
  printf '%s\n' "$out" > "${RUN_DIR}/raw/$1.txt"
  [ "$code" -eq 0 ]
}
expect "dry-run DELETE of the SNR template succeeds without admission" \
  dry_delete 16-dry-delete-template selfnoderemediationtemplate self-node-remediation-automatic-strategy-template
expect "dry-run DELETE of the SNR config succeeds (its webhook covered DELETE)" \
  dry_delete 16-dry-delete-config selfnoderemediationconfig self-node-remediation-config
expect "template still exists after the dry-run" found selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
expect "config still exists after the dry-run" found selfnoderemediationconfig self-node-remediation-config -n "$NS"
snapshot 16
