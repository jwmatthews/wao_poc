#!/usr/bin/env bash
# test/cluster/05-enable-nhc.sh — WAO-INST-05: enable NHC. Admission is probed with server dry-run only;
# no NodeHealthCheck policy is ever created.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-05 enable NHC"
set_state 05 nodeHealthCheck Enabled
wait_for 300 "NHC manager Available" deployment_available node-healthcheck-controller-manager
wait_for 180 "webhook CA bundle injected" ca_injected validatingwebhookconfiguration/node-healthcheck-validating-webhook-configuration
wait_for 180 "status phase Available" phase_is nodeHealthCheck Available
expect "status admissionReady true" field_is nodeHealthCheck admissionReady true
expect "every rendered NHC operand object exists" operands_present nhc
expect "service-ca created the webhook serving Secret with tls.crt and tls.key (key names only)" \
  secret_has_keys "$NS" node-healthcheck-webhook-server-cert tls.crt tls.key

# Admission: both minHealthy and maxUnhealthy must be rejected by the webhook (no CRD rule covers it). Dry-run only.
expect "invalid NHC rejected (dry-run)" dry_run_rejected 05-admission-invalid apply <<YAML
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: wao-inst-05-invalid
spec:
  minHealthy: 51%
  maxUnhealthy: 1
  selector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: self-node-remediation-automatic-strategy-template
    namespace: ${NS}
YAML
expect "rejection came from vnodehealthcheck.kb.io" grep -q "vnodehealthcheck.kb.io" <<<"$DRY_RUN_OUT"
expect "rejection names the minHealthy/maxUnhealthy rule" grep -q "cannot be specified at the same time" <<<"$DRY_RUN_OUT"

wait_for 120 "NHC initializer created the aggregation ClusterRole" found clusterrole node-healthcheck-operator-aggregation
record 05-consoleplugin get consoleplugin node-remediation-console-plugin -o json >/dev/null 2>&1 \
  && echo "note: NHC created ConsolePlugin node-remediation-console-plugin" || echo "note: no ConsolePlugin created"
record 05-servicemonitor get servicemonitor -n "$NS" -o json >/dev/null 2>&1 \
  && echo "note: ServiceMonitor API present (see raw 05-servicemonitor)" || echo "note: ServiceMonitor API absent"
expect "no NodeHealthCheck policy exists" none_found nodehealthcheck
record 05-manager-logs logs deployment/node-healthcheck-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 05
