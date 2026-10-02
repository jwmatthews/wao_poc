#!/usr/bin/env bash
# test/cluster/03-clean-install.sh — WAO-INST-03: installing WAO creates nothing component-related. Read-only.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-03 clean-install invariants (read-only)"
expect "only the WAO Deployment exists in $NS" only_wao_deployment
expect "no DaemonSet in $NS" none_found daemonset -n "$NS"
expect "no Service in $NS" none_found service -n "$NS"
only_wao_pods() {
  jcheck 'all(i["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "workload-availability-operator" for i in o["items"])' \
    get pods -n "$NS"
}
expect "the only pods in $NS are WAO controller pods (no node agents)" only_wao_pods
for c in nhc snr sbr far mdr nmo; do
  expect "no $c operand object exists" operands_absent "$c"
done
expect "no object of any of the twelve component kinds exists anywhere" no_component_objects
expect "no medik8s (*.kb.io) webhook configuration exists" no_medik8s_webhooks
expect "no PVC in $NS" none_found pvc -n "$NS"
expect "no medik8s-leases namespace" absent namespace medik8s-leases
snapshot 03
