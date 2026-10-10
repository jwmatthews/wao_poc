#!/usr/bin/env bash
# test/cluster/15-disable-nmo-nhc.sh — WAO-INST-15: disable NMO and NHC; record what upstream NHC leaves behind.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-15 disable NMO and NHC"
record 15-disable patch workloadavailabilityconfig cluster --type merge \
  -p '{"spec":{"components":{"nodeMaintenance":{"state":"Disabled"},"nodeHealthCheck":{"state":"Disabled"}}}}' >/dev/null
for pair in nmo:nodeMaintenance nhc:nodeHealthCheck; do
  dir="${pair%%:*}"; key="${pair#*:}"
  wait_for 180 "$key phase Disabled" phase_is "$key" Disabled
  wait_for 180 "$key operand objects removed" operands_absent "$dir"
  expect "every rendered $dir object is gone (Deployment, Services, ServiceAccounts, roles, bindings, webhook)" operands_absent "$dir"
  expect "nothing labelled component=$key remains" labelled_absent "$key"
  wait_for 180 "$key manager pods gone" none_found pods -n "$NS" -l "workloadavailability.medik8s.io/component=$key"
  expect "$key admissionReady false" field_is "$key" admissionReady false
  expect "$key has no retainedResources" field_is "$key" retainedResources null
done
expect "WAO removed the CA ConfigMap it owned" absent configmap node-healthcheck-ca-bundle -n "$NS"
expect "WAO removed the console backend" absent deployment node-healthcheck-node-remediation-console-plugin -n "$NS"
# Administrator cleanup of what the harness enabled in WAO-INST-05 (WAO never edits Console/cluster, KI-1).
if console_plugin_enabled node-remediation-console-plugin; then
  others=$(console_plugins | python3 -c 'import json, sys; print(json.dumps([p for p in json.load(sys.stdin) if p != "node-remediation-console-plugin"]))')
  disable_console_plugin 15-disable-plugin node-remediation-console-plugin
  expect "plugin entry removed from Console/cluster, other entries preserved" \
    python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)' "$others" "$(console_plugins)"
fi
expect "no NHC webhook name is registered" no_webhook_matching 'vnodehealthcheck\.kb\.io'
expect "no NMO webhook name is registered" no_webhook_matching 'vnodemaintenance\.kb\.io'
expect "the NHC and NMO CRDs remain" crds_present "nodehealthchecks.remediation.medik8s.io nodemaintenances.nodemaintenance.medik8s.io"

# Objects upstream NHC (and, for the lease namespace, NMO) created at runtime, not WAO. They are expected to remain; record them.
leftover() { # leftover DESCRIPTION ARGS... : print LEFTOVER when `k get ARGS` finds the object
  local desc="$1"; shift
  if found "$@" >/dev/null 2>&1; then echo "LEFTOVER: $desc (created by the upstream component, not WAO)"; else echo "note: $desc not present"; fi
}
leftover "ClusterRole node-healthcheck-operator-aggregation" clusterrole node-healthcheck-operator-aggregation
leftover "ClusterRoleBinding node-healthcheck-operator-aggregation" clusterrolebinding node-healthcheck-operator-aggregation
leftover "ConsolePlugin node-remediation-console-plugin" consoleplugin node-remediation-console-plugin
leftover "namespace medik8s-leases" namespace medik8s-leases
leftover "ServiceMonitor node-healthcheck-controller-manager-metrics-monitor" servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS"
for s in node-healthcheck-webhook-server-cert node-maintenance-operator-webhook-server-cert node-healthcheck-tls nrc-plugin-cert; do
  found secret "$s" -n "$NS" >/dev/null 2>&1 && echo "LEFTOVER: service-ca Secret $s (created by service-ca, not WAO)" || true
done
record 15-nhc-leftovers get clusterrole,clusterrolebinding node-healthcheck-operator-aggregation -o name >/dev/null 2>&1 || true
snapshot 15
