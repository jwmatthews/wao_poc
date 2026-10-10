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
# ---- OpenShift platform integration (D11): metrics mTLS (issue #3) ----
wait_for 300 "console backend Available" deployment_available node-healthcheck-node-remediation-console-plugin
expect "status lists both NHC Deployments ready" jcheck \
  'sorted(d["name"] for c in o["status"]["components"] if c["name"] == "nodeHealthCheck" for d in c["deployments"] if d["ready"]) == ["node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"]' \
  get workloadavailabilityconfig cluster
expect "service-ca issued the metrics serving Secret node-healthcheck-tls (key names only)" secret_has_keys "$NS" node-healthcheck-tls tls.crt tls.key
expect "service-ca issued the console serving Secret nrc-plugin-cert (key names only)" secret_has_keys "$NS" nrc-plugin-cert tls.crt tls.key
ca_injected_cm() { jcheck '"BEGIN CERTIFICATE" in ((o.get("data") or {}).get("service-ca.crt") or "")' get configmap node-healthcheck-ca-bundle -n "$NS"; }
wait_for 120 "service-ca injected service-ca.crt into node-healthcheck-ca-bundle" ca_injected_cm
expect "manager mounts the metrics serving certificate read-only at /etc/tls/private" jcheck \
  'any(m["mountPath"] == "/etc/tls/private" and m.get("readOnly") for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "manager" for m in c.get("volumeMounts") or [])' \
  get deployment node-healthcheck-controller-manager -n "$NS"
expect "manager log reports metrics mTLS configured" bash -c 'k logs deployment/node-healthcheck-controller-manager -n "$NS" --all-containers --tail=500 | grep -q "Configuring secure metrics with mTLS"'
wait_for 120 "NHC created its ServiceMonitor" found servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS"
expect "ServiceMonitor selector matches the metrics Service labels" sm_selects_service
expect "ServiceMonitor is owned by the manager Deployment (garbage-collected on disable)" jcheck \
  'any(r["kind"] == "Deployment" and r["name"] == "node-healthcheck-controller-manager" for r in o["metadata"].get("ownerReferences") or [])' \
  get servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS"
nhc_targets_up() { prom_all_values 'up{namespace="'"$NS"'",job="node-healthcheck-controller-manager-metrics-service"}' 1; }
wait_for 300 "platform Prometheus scrapes every NHC target (up == 1)" nhc_targets_up
no_rejected_sm() { prom_all_values 'prometheus_operator_managed_resources{job="prometheus-operator",namespace="openshift-monitoring",resource="ServiceMonitor",state="rejected"}' 0; }
wait_for 300 "Prometheus operator rejects no ServiceMonitor" no_rejected_sm
prom_query 'up{namespace="'"$NS"'"}' > "${RUN_DIR}/raw/05-prometheus-targets.json" || true
expect "the rejected-ServiceMonitor alert is not firing" bash -c '[ "$(prom_query "ALERTS{alertname=\"PrometheusOperatorRejectedResources\",alertstate=\"firing\"}")" = "[]" ]'

# ---- console backend (issue #4): trusted fetch, then the administrator enables the plugin ----
record 05-consoleplugin get consoleplugin node-remediation-console-plugin -o json >/dev/null
expect "ConsolePlugin backend points at the WAO-rendered Service" jcheck \
  'o["spec"]["backend"]["service"] == {"name": "node-healthcheck-node-remediation-console-plugin", "namespace": os.environ["NS"], "port": 9443, "basePath": "/"}' \
  get consoleplugin node-remediation-console-plugin
manifest=$(trusted_fetch 05-manifest "https://node-healthcheck-node-remediation-console-plugin.${NS}.svc:9443/plugin-manifest.json") || manifest=""
printf '%s\n' "$manifest" > "${RUN_DIR}/raw/05-plugin-manifest.json"
expect "plugin manifest served over TLS trusted by the service CA and names the plugin" \
  python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1])["name"] == "node-remediation-console-plugin" else 1)' "$manifest"
before_plugins=$(console_plugins)
enable_console_plugin 05-enable-plugin node-remediation-console-plugin   # administrator action, not WAO (known issue KI-1)
expect "plugin enabled in Console/cluster" console_plugin_enabled node-remediation-console-plugin
expect "previously enabled plugins preserved" python3 -c 'import json, sys; sys.exit(0 if set(json.loads(sys.argv[1])) <= set(json.loads(sys.argv[2])) else 1)' "$before_plugins" "$(console_plugins)"
console_rolled_out() {
  jcheck 'o["status"].get("observedGeneration") == o["metadata"]["generation"] and o["status"].get("readyReplicas") == o["spec"]["replicas"] and o["status"].get("updatedReplicas") == o["spec"]["replicas"] and not o["status"].get("unavailableReplicas")' \
    get deployment console -n openshift-console
}
sleep 30   # give the console operator time to pick up the new plugin list before checking the rollout
wait_for 600 "OpenShift console Deployment rolled out with the new plugin list" console_rolled_out
record 05-console-plugins get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' >/dev/null
echo "note: browser verification of the Node Remediation UI is manual (docs/known-issues.md KI-7)"
expect "no NodeHealthCheck policy exists" none_found nodehealthcheck
record 05-manager-logs logs deployment/node-healthcheck-controller-manager -n "$NS" --tail=200 >/dev/null
snapshot 05
