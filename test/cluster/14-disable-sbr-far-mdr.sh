#!/usr/bin/env bash
# test/cluster/14-disable-sbr-far-mdr.sh — WAO-INST-14: disabling SBR, FAR and MDR removes everything WAO created
# for them, keeps their CRDs, and reports nothing retained (none of them started agents or native objects).
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-14 disable SBR, FAR, MDR"
record 14-disable patch workloadavailabilityconfig cluster --type merge \
  -p '{"spec":{"components":{"storageBasedRemediation":{"state":"Disabled"},"fenceAgentsRemediation":{"state":"Disabled"},"machineDeletionRemediation":{"state":"Disabled"}}}}' >/dev/null
for pair in sbr:storageBasedRemediation far:fenceAgentsRemediation mdr:machineDeletionRemediation; do
  dir="${pair%%:*}"; key="${pair#*:}"
  wait_for 180 "$key phase Disabled" phase_is "$key" Disabled
  wait_for 180 "$key operand objects removed" operands_absent "$dir"
  expect "every rendered $dir object is gone (Deployment, Services, ServiceAccounts, roles, bindings, webhooks)" operands_absent "$dir"
  expect "nothing labelled component=$key remains" labelled_absent "$key"
  wait_for 180 "$key manager pods gone" none_found pods -n "$NS" -l "workloadavailability.medik8s.io/component=$key"
  expect "$key has no retainedResources" field_is "$key" retainedResources null
done
expect "SBR reports no admissionReady field" field_is storageBasedRemediation admissionReady null
expect "MDR reports no admissionReady field" field_is machineDeletionRemediation admissionReady null
expect "FAR reports admissionReady false" field_is fenceAgentsRemediation admissionReady false
expect "the seven SBR, FAR and MDR CRDs remain" crds_present "$(printf '%s\n' "$COMPONENT_CRDS" | grep -E 'storage-based|fence-agents|machine-deletion')"
expect "no FAR webhook name is registered" no_webhook_matching fenceagentsremediation
if found secret fence-agents-remediation-webhook-server-cert -n "$NS" >/dev/null 2>&1; then
  echo "LEFTOVER: service-ca Secret fence-agents-remediation-webhook-server-cert (created by service-ca, not WAO)"
fi
snapshot 14
