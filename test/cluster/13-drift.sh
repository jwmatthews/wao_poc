#!/usr/bin/env bash
# test/cluster/13-drift.sh — WAO-INST-13: WAO repairs drift on an operand and owns the field it repairs.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-13 drift repair and field ownership"
dep=sbr-operator-controller-manager
expect "$dep starts with 2 replicas" jcheck 'o["spec"]["replicas"] == 2' get deployment "$dep" -n "$NS"
record 13-scale scale deployment "$dep" -n "$NS" --replicas=0 >/dev/null
replicas_restored() { jcheck 'o["spec"]["replicas"] == 2' get deployment "$dep" -n "$NS"; }
expect "WAO restores 2 replicas within 60 s" wait_for 60 "spec.replicas back to 2" replicas_restored
wait_for 300 "$dep Available again" deployment_available "$dep"
record 13-deployment get deployment "$dep" -n "$NS" -o json >/dev/null
expect "managedFields: manager workload-availability-operator (Apply) owns spec.replicas" \
  jcheck 'any(m.get("manager") == "workload-availability-operator" and m.get("operation") == "Apply" and "f:replicas" in (m.get("fieldsV1") or {}).get("f:spec", {}) for m in o["metadata"].get("managedFields") or [])' \
  get deployment "$dep" -n "$NS" --show-managed-fields
wait_for 120 "storageBasedRemediation phase Available" phase_is storageBasedRemediation Available
snapshot 13
