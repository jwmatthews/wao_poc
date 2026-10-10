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
# ---- NHC CA ConfigMap (D11): WAO recreates it after deletion and repairs its annotation; service-ca re-injects the key ----
cm=node-healthcheck-ca-bundle
cm_uid=$(k get configmap "$cm" -n "$NS" -o jsonpath='{.metadata.uid}')
record 13-delete-ca-configmap delete configmap "$cm" -n "$NS" >/dev/null
cm_recreated() { jcheck 'o["metadata"]["uid"] != os.environ["CM_UID"] and o["metadata"].get("annotations", {}).get("service.beta.openshift.io/inject-cabundle") == "true"' get configmap "$cm" -n "$NS"; }
export CM_UID="$cm_uid"
expect "WAO recreates $cm within 120 s with the inject-cabundle annotation" wait_for 120 "$cm recreated" cm_recreated
cm_injected() { jcheck '"BEGIN CERTIFICATE" in ((o.get("data") or {}).get("service-ca.crt") or "")' get configmap "$cm" -n "$NS"; }
expect "service-ca re-injects service-ca.crt within 120 s" wait_for 120 "service-ca.crt injected" cm_injected
record 13-strip-ca-annotation annotate configmap "$cm" -n "$NS" service.beta.openshift.io/inject-cabundle- >/dev/null
cm_repaired() { jcheck 'o["metadata"].get("annotations", {}).get("service.beta.openshift.io/inject-cabundle") == "true" and "BEGIN CERTIFICATE" in ((o.get("data") or {}).get("service-ca.crt") or "")' get configmap "$cm" -n "$NS"; }
expect "WAO restores the inject-cabundle annotation within 120 s and the injected key survives" wait_for 120 "annotation restored" cm_repaired
record 13-ca-configmap get configmap "$cm" -n "$NS" -o json >/dev/null
snapshot 13
