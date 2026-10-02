#!/usr/bin/env bash
# test/cluster/17-delete-config.sh — WAO-INST-17: deleting the config runs the finalizer; a WAO restart re-creates
# an all-Disabled config (D4). SNR agents and their objects are retained.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-17 delete the config"
record 17-wac-before get wac cluster -o json >/dev/null
record 17-delete-wac delete workloadavailabilityconfig cluster --wait=false >/dev/null
wait_for 180 "config deleted (finalizer completed)" absent wac cluster
expect "only the WAO Deployment remains in $NS" only_wao_deployment
for c in nhc snr sbr far mdr nmo; do
  expect "no $c operand object remains" operands_absent "$c"
done
expect "no medik8s webhook configuration remains" no_medik8s_webhooks
expect "SNR agent DaemonSet retained" found daemonset self-node-remediation-ds -n "$NS"
expect "SNR config retained" found selfnoderemediationconfig self-node-remediation-config -n "$NS"
expect "SNR template retained" found selfnoderemediationtemplate self-node-remediation-automatic-strategy-template -n "$NS"
expect "SNR Secret self-node-remediation-certificates retained (existence only)" found secret self-node-remediation-certificates -n "$NS"
expect "all thirteen CRDs retained" crds_present "$ALL_CRDS"
expect "WAO does not re-create the config while running" absent wac cluster

restart_wao 17
wait_for 180 "new config 'cluster' with six component statuses" \
  jcheck 'len(o.get("status", {}).get("components") or []) == 6' get wac cluster
record 17-wac-after get wac cluster -o json >/dev/null
expect "new config is all Disabled (spec and desiredState)" jcheck '
all(o.get("spec", {}).get("components", {}).get(k, {}).get("state", "Disabled") == "Disabled" for k in os.environ["COMPONENT_KEYS"].split())
and all(c["desiredState"] == "Disabled" for c in o["status"]["components"])' get wac cluster
expect "the five components without agents report phase Disabled" \
  jcheck 'all(c["phase"] == "Disabled" for c in o["status"]["components"] if c["name"] != "selfNodeRemediation")' get wac cluster
wait_for 120 "SNR honestly reports DisableIncomplete (agents retained)" phase_is selfNodeRemediation DisableIncomplete
expect "no operand Deployment was re-created" only_wao_deployment
snapshot 17
