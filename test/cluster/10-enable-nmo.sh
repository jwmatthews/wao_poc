#!/usr/bin/env bash
# test/cluster/10-enable-nmo.sh — WAO-INST-10: enable NMO. Never creates a real NodeMaintenance (that would drain a node).
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-10 enable NMO"
set_state 10 nodeMaintenance Enabled
wait_for 300 "NMO manager Available" deployment_available node-maintenance-operator-controller-manager
wait_for 180 "webhook CA bundle injected" ca_injected validatingwebhookconfiguration/node-maintenance-operator-validating-webhook-configuration
wait_for 180 "status phase Available" phase_is nodeMaintenance Available
expect "status admissionReady true" field_is nodeMaintenance admissionReady true
expect "every rendered NMO operand object exists" operands_present nmo
expect "service-ca created the webhook serving Secret with tls.crt and tls.key (key names only)" \
  secret_has_keys "$NS" node-maintenance-operator-webhook-server-cert tls.crt tls.key

expect "NodeMaintenance for a missing node rejected (dry-run)" dry_run_rejected 10-admission-missing-node create <<'YAML'
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: wao-inst-10-probe
spec:
  nodeName: wao-node-that-does-not-exist
  reason: WAO-INST-10 admission probe (dry-run only)
YAML
expect "rejection came from vnodemaintenance.kb.io" grep -q "vnodemaintenance.kb.io" <<<"$DRY_RUN_OUT"
expect "rejection names the missing node" grep -q "no node with name" <<<"$DRY_RUN_OUT"
expect "no NodeMaintenance objects exist" none_found nodemaintenances
if found namespace medik8s-leases >/dev/null 2>&1; then
  echo "note: medik8s-leases namespace exists (shared by NHC and NMO by default)"
else
  echo "note: medik8s-leases not created yet (created on first node lease)"
fi
record 10-manager-logs logs deployment/node-maintenance-operator-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 10
