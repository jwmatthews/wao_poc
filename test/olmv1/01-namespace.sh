#!/usr/bin/env bash
# test/olmv1/01-namespace.sh — experiment 0001 step 1: create the install namespace with the
# privileged Pod Security Admission labels the RHWA operators need (SNR/SBR agents run privileged).
# Under OLM Classic the Subscription flow creates this namespace; under OLM v1 the admin does.
source "$(dirname "$0")/lib.sh"
echo "== 0001-01 namespace $NS"
if absent namespace "$NS"; then
  record 01-create-ns create namespace "$NS" >/dev/null
fi
record 01-label-ns label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  security.openshift.io/scc.podSecurityLabelSync=false >/dev/null
expect "namespace $NS exists with privileged PSA enforce" \
  jcheck 'o["metadata"]["labels"].get("pod-security.kubernetes.io/enforce")=="privileged"' get namespace "$NS"
record 01-ns get namespace "$NS" -o json >/dev/null
outcome 0001-01 PASS "namespace created with privileged PSA labels"
