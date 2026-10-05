#!/usr/bin/env bash
# test/cluster/09-enable-mdr.sh — WAO-INST-09: enable MDR and verify shared-namespace selector isolation (D10).
# No MachineDeletionRemediation is ever created.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-09 enable MDR"
record 09-machine-api get crd machines.machine.openshift.io -o name >/dev/null 2>&1 || echo "note: Machine API absent; MDR cannot act on this cluster"
set_state 09 machineDeletionRemediation Enabled
wait_for 300 "MDR manager Available" deployment_available machine-deletion-remediation-controller-manager
wait_for 180 "status phase Available" phase_is machineDeletionRemediation Available
expect "status has no admissionReady field" field_is machineDeletionRemediation admissionReady null
expect "every rendered MDR operand object exists" operands_present mdr

svc=machine-deletion-remediation-controller-manager-metrics-service
expect "MDR metrics Service selector carries the component label" \
  jcheck 'o["spec"]["selector"].get("workloadavailability.medik8s.io/component") == "machineDeletionRemediation"' get service "$svc" -n "$NS"

other_managers() { # pods sharing MDR's upstream selector that are not MDR pods
  k get pods -n "$NS" -l 'control-plane=controller-manager,workloadavailability.medik8s.io/component!=machineDeletionRemediation' -o name | wc -l | tr -d ' '
}
n_other=$(other_managers)
echo "note: ${n_other} other control-plane=controller-manager pods share the namespace with MDR"
expect "other managers carrying control-plane=controller-manager run in $NS (the isolation check is meaningful)" test "$n_other" -gt 0

mdr_pods() { k get pods -n "$NS" -l workloadavailability.medik8s.io/component=machineDeletionRemediation -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }
ep_pods() { k get endpointslices -n "$NS" -l "kubernetes.io/service-name=$svc" -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}' | sort; }
endpoints_are_mdr() {
  local m e
  m=$(mdr_pods) || return 1
  e=$(ep_pods) || return 1
  [ -n "$e" ] && [ "$e" = "$m" ]
}
wait_for 120 "MDR metrics EndpointSlices settle on the MDR pods" endpoints_are_mdr || true
record 09-endpointslices get endpointslices -n "$NS" -l "kubernetes.io/service-name=$svc" -o json >/dev/null
expect "MDR metrics endpoints are exactly the MDR pods" endpoints_are_mdr
expect "no MachineDeletionRemediation exists" none_found machinedeletionremediations -A
snapshot 09
